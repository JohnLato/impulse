{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TupleSections #-}

{-# OPTIONS_GHC -Wall #-}
-- The first step of compiling is to build all reactimated 'Event's into a
-- graph.  The graph structure keeps track of the current heads.
module Reactive.Impulse.Graph (
  initialRunningDynGraph
, compileHeadMap
, dynUpdateGraph
)
where

import Reactive.Impulse.Weak
import Reactive.Impulse.Core
import Reactive.Impulse.Internal.RWST hiding ((<>))
import Reactive.Impulse.Internal.Types
import Reactive.Impulse.Chain

import Control.Applicative
import Control.Concurrent.STM
import Control.Lens
import Control.Monad.Identity

import Data.IntMap (IntMap)
import qualified Data.IntMap as IM
import Data.IntSet (IntSet)
import qualified Data.IntSet as IntSet
import Data.IntSet.Lens
import Data.Semigroup

import System.Mem.Weak
import GHC.Conc.Sync (unsafeIOToSTM)
import Unsafe.Coerce

initialRunningDynGraph :: IO RunningDynGraph
initialRunningDynGraph = do
    tv1 <- newTVarIO mempty
    tv2 <- newTVarIO mempty
    return $ DynGraph tv1 tv2 mempty IM.empty

compileHeadMap :: SGState -> IO NetHeadMap
compileHeadMap sg = do
    mapvar <- newTVarIO IM.empty
    traverse (mkDynInput mapvar) (sg^.inputs) >>=
        atomically . writeTVar mapvar . IM.fromList
    return mapvar
  where
    mkDynInput :: NetHeadMap -> SGInput -> IO (Label, EInput)
    mkDynInput mapvar (SGInput t e) =
        let !l = e^.label
            finishIt = Just . atomically $
                modifyTVar' mapvar (IM.delete l)
        in (l,) . EInput <$> mkWeakTVar t finishIt 

runFireOnce :: Network -> FireOnce -> IO ()
runFireOnce net (FireOnce l a) = do
    nIn <- net^!nInputs.act readTVarIO
    oneRan <- IM.lookup l nIn^!_Just.act (\(EInput wk) -> deRefWeak wk >>= \case
                Just tv -> Any True <$ (readTVarIO tv >>= ($ unsafeCoerce a))
                Nothing -> return mempty)
    when (not $ getAny oneRan) $ do
      rg <- net^!nDynGraph.dgHeads.act readTVarIO
      IM.lookup l rg^!act (\(Just wk) -> deRefWeak wk >>= \case
          Just (EChain _ c) -> (runUpdates net $ compileChain c id (unsafeCoerce a))
          _ -> error $ "impulse <runFireOnce>: chain expired: " ++ show l )

-- dynamically update a network with the given ChainM building action
-- we convet the ChainM into a ModGraphM to update a frozen graph,
-- then freeze the network and run the ModGraphM against the now-frozen network.
-- next we merge the results of the build step, recompile everything that's been
-- marked dirty, and finally unfreeze the network, returning any 'onBuild'-type
-- actions.
dynUpdateGraph :: Network -> ChainM () -> STM (IO ())
dynUpdateGraph net builder = do
    let rg = net^.nDynGraph
        runDyn :: ModGraphM DirtyLog
        runDyn = do
            baseGraph   <- view frozenMutGraph
            baseBuilder <- get  -- this should always be empty I think
            (_,output,dirtyLog) <- lift
                $ runRWST builder (boundSet baseGraph) baseBuilder
            put output
            return dirtyLog
        blarh = do
            dl <- runDyn
            prepareForMerge $ dl^.dlRemSet
            s <- get
            return (dl,s)
    (dirties2,final,(dirtyLog,finalGraph)) <- replacingRunningGraph rg blarh
    let pushEvents = appEndo (dirtyLog^.dlEvents) []
        dirties = dirties2 <> dirtyLog^.dlChains
    knownInputs <- net^!nInputs.act readTVar

    let recompile :: Label -> EChain -> STM ()
        recompile lbl (EChain _ c) = IM.lookup lbl knownInputs^!_Just.act (
          \(EInput wk) -> wk^!act (unsafeIOToSTM .deRefWeak)._Just.act (
          \pushVar -> let cc = compileChain (unsafeCoerce c) id
                      in writeTVar pushVar $ runUpdates net . cc ))

        -- we only want to run the action for each node once.  For some reason
        -- I think we may have multiple occurrences of them.
        -- TODO: see if this step is really necessary.
        checkFireOnce :: IntSet -> FireOnce -> IO IntSet
        checkFireOnce acc fo
          | IntSet.member (fo^.label) acc = return acc
          | otherwise = IntSet.insert (fo^.label) acc <$ runFireOnce net fo

    mapMOf_ (from dirtyChains.members)
        (\lbl -> finalGraph ^! dgHeads.unwrapped.to (IM.lookup lbl)._Just
              .unwrapped.act (recompile lbl))
        dirties

    return $ final >> void (foldM checkFireOnce mempty pushEvents)

-- perform an operation on a 'RunningDynGraph', and re-write it when
-- finished.
-- return the dirty heads so we know which to rebuild,
-- and which pushers to update.
replacingRunningGraph :: RunningDynGraph -> ModGraphM a -> STM (DirtyChains,IO (), a)
replacingRunningGraph g m = do
    f <- freezeDynGraph
    (a,newG,dirtyLog) <- runRWST m f startBuildingGraph
    final <- thawFrozen dirtyLog newG
    return (dirtyLog^.dlChains,final,a)
  where
    freezeDynGraph :: STM FrozenDynGraph
    freezeDynGraph = do
        let freezeMap :: Lens' (DynGraph TVar Weak) (TVar (IntMap (Weak a)))
                         -> STM (IntMap (Weak a), IntMap (Maybe a))
            freezeMap l = do
              w' <- g ^! l.act readTVar
              m' <- traverse (unsafeIOToSTM.deRefWeak) w'
              return (w',m')
        (heads'w,heads'm) <- freezeMap dgHeads
        (behs'w,behs'm) <- freezeMap dgBehaviors

        let noMaybes = IM.mapMaybe (fmap Identity)
            sourcegraph = startBuildingGraph
                            & dgHeads.unwrapped .~ heads'w
                            & dgBehaviors.unwrapped .~ behs'w
            mutgraph = startBuildingGraph
                        & dgHeads.unwrapped .~ noMaybes heads'm
                        & dgBehaviors.unwrapped .~ noMaybes behs'm
        return $ emptyFrozenGraph & frozenMutGraph .~ mutgraph
                  & frozenSource .~ sourcegraph

    thawFrozen :: DirtyLog -> BuildingDynGraph -> STM (IO ())
    thawFrozen dirtyLog newg = do
        -- run this as a finalizer action, because we won't need heads for
        -- anything else and we can't trust mkWeak inside STM.
        -- Get all the dirty heads out of the mutgraph, make new weak refs,
        -- and update the map. Have the STM action be a union so we don't need
        -- to worry about existing elements.  `union` is left-biased, so we
        -- want to merge our new map (which might have updated dirties) as the
        -- left.
        --
        -- this is a little harder than the generic reconstitutor because we
        -- only want to change things that have been dirtied, whereas in other
        -- cases we can add everything.
        let dirties = dirtyLog^.dlChains
            mkAWeakRef t =
                       let !lbl = t^.label
                           mkw = newg^.dgMkWeaks.to (IM.lookup lbl)
                           evictor = Just $ evictHead g lbl
                       in maybe (error $ "impulse <replacingRunningGraph>: warning: missing MkWeak for " ++ show lbl)
                                (\w -> unMkWeak w t evictor)
                                mkw
            folder map' dirtyLbl = do
                    h' <- traverse (mkAWeakRef.runIdentity)
                             $ newg^.dgHeads.unwrapped.to (IM.lookup dirtyLbl)
                    return $! maybe id (IM.insert dirtyLbl) h' map'
            mkWeakHeads = do
              mg1 <- foldlMOf (from dirtyChains.members) folder mempty dirties
              atomically $ g^!dgHeads.act (flip modifyTVar' (IM.union mg1))

        -- for behaviors et al, do the same thing, except we don't need to
        -- worry about dirties (just add everything)
        let mkAWeakB t = let !lbl = t^.label
                             eviction = Just $ evictBehavior g lbl
                         in weakEB eviction t
            mkWeakBs = reconstituter dgBehaviors mkAWeakB 

            reconstituter :: (forall f w. Lens' (DynGraph f w) (f (IntMap (w t)))) -> (t -> IO (Weak t)) -> IO ()
            reconstituter fieldLens weakor = do
                mb1 <- traverse (weakor.runIdentity)
                        $ newg^.fieldLens.unwrapped
                atomically $ g^!fieldLens.act (flip modifyTVar' (IM.union mb1))
        return $ mkWeakHeads >> mkWeakBs

-- This function takes the constructed BuildingDynGraph in ModGraphM's state
-- and merges it with the frozenMutGraph, putting the merged graph back into
-- the state.  This should only be called immediately before unfreezing the
-- state.
prepareForMerge :: ChainEdgeMap -> ModGraphM ()
prepareForMerge cem = do
    -- the initial, frozen graph.
    baseg <- view $ frozenMutGraph.dgHeads.unwrapped
    -- we need to prune the pre-existing graph.  The new chains should
    -- already be pruned though, so we can leave them be.
    let remSet = cem^.from chainEdgeMap.to (IM.keysSet)
        pruneEChain e@(EChain p c) = if not . IntSet.null . IntSet.intersection remSet $ c^.cPushSet'
            then (DirtyChains $ IntSet.singleton (c^.label), EChain p $ removeEdges cem c)
            else (mempty, e)
    let doAcc :: DirtyChains -> EChain -> (DirtyChains,EChain)
        doAcc !s e = pruneEChain e & _1 <>~ s
        (rmDirties, baseg') = mapAccumLOf (traverse.unwrapped) doAcc mempty baseg
    scribe dlChains rmDirties
    -- the built sub-graph to add
    newg  <- get
    newg' <- foldlMOf (dgHeads.unwrapped.traverse.unwrapped)
                (procNewHead $ newg^.dgBoundMap ) baseg' newg

    dgHeads.unwrapped.=newg'
  where
    procNewHead :: BoundaryMap -> IntMap (Identity EChain) -> EChain
                -> ModGraphM (IntMap (Identity EChain))
    procNewHead boundMap runningGraph newHead = do
    -- 1. for each head in BuildingDynGraph
    --      *. if the label isn't known, copy over the head and mark it dirty
    --      *. if the label is known (it exists in the BoundaryMap),
    --          push the head into the graph, and mark all parents dirty.
        let lbl = newHead^.label
            parentSet = boundMap^.from boundaryMap.to (IM.lookup lbl)._Just
            f' (EChain p ec) = EChain p $ IntSet.foldl'
                              (\c l' -> insertAt l' newHead c) ec parentSet
        if IntSet.null parentSet
              then IM.insert lbl (Identity newHead) runningGraph
                   <$ markDirty lbl
              else IM.map (over unwrapped f') runningGraph
                   <$ markDirties parentSet

boundSet :: BuildingDynGraph -> BoundarySet
boundSet g = g^.dgHeads.unwrapped.traverse.unwrapped.cBoundarySet

runUpdates :: Network -> STM [UpdateStep] -> IO ()
runUpdates network doStep = (atomically $ doStep >>= runStep) >>= sequence_
  where
    runStep :: [UpdateStep] -> STM [IO ()]
    runStep = sequence.map (either (dynUpdateGraph network) id)

------------------------------------------------------------------
-- helpers for handling weak refs.

-- make a weak reference for an EBehavior
weakEB :: Maybe (IO ()) -> EBehavior -> IO (Weak EBehavior)
weakEB finalizer e@(EBehavior _ cb) = case cb of
    ReadCB a  -> mkWeak a e finalizer
    PushCB tv -> mkWeakTVarKey tv e finalizer
    SwchCB (CBSwitch tv) -> mkWeakTVarKey tv e finalizer

-- eviction function for behaviors
evictBehavior :: RunningDynGraph -> Label -> IO ()
evictBehavior rg lbl = atomically $
    rg ^! dgBehaviors.act (flip modifyTVar' (IM.delete lbl))

evictHead :: RunningDynGraph -> Label -> IO ()
evictHead rg lbl = atomically $
    rg ^! dgHeads.act (flip modifyTVar' (IM.delete lbl))
