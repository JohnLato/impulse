{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TupleSections #-}

{-# OPTIONS_GHC -Wall #-}
-- The first step of compiling is to build all reactimated 'Event's into a
-- graph.  The graph structure keeps track of the current heads.
module Reactive.Impulse.Internal.Graph (
  initialRunningDynGraph
, compileHeadMap
, dynUpdateGraph
)
where

import Reactive.Impulse.Core
import Reactive.Impulse.Internal.RWST hiding ((<>))
import Reactive.Impulse.Internal.Types
import Reactive.Impulse.Internal.Chain
import Reactive.Impulse.Internal.Weak
import Reactive.Impulse.STM.Fence

import Control.Applicative
import Control.Concurrent.STM hiding (mkWeakTVar)
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
import System.IO.Unsafe (unsafePerformIO)
import Unsafe.Coerce

initialRunningDynGraph :: IO RunningDynGraph
initialRunningDynGraph = do
    tv1 <- newTVarIO mempty
    tv2 <- newTVarIO mempty
    return $ DynGraph tv1 tv2 mempty IM.empty mempty

compileHeadMap :: SGState -> IO NetHeadMap
compileHeadMap sg = do
    mapvar <- newTVarIO IM.empty
    addToHeadMap mapvar $ sg^.inputs.to IM.elems
    return mapvar

addToHeadMap :: NetHeadMap -> [SGInput] -> IO ()
addToHeadMap mapvar sgInputs = do
    currentHeads <- readTVarIO mapvar
    mTrace $ "curHeads" ++ show (IM.keys currentHeads)
    currentHeads2 <- foldM folder currentHeads sgInputs
    atomically $ writeTVar mapvar currentHeads2
    mTrace $ "curHeads(added)" ++ show (IM.keys currentHeads2)
  where
    folder !acc i   = (\(l,e) -> IM.insert l e acc) <$> mkDynInput i
    mkDynInput :: SGInput -> IO (Label, EInput)
    mkDynInput (SGInput t e) =
        let !l = e^.label
            finishIt = Just . atomically $
                modifyTVar' mapvar (IM.delete l)
        in (l,) . EInput <$> mkWeakTVar t finishIt

addToHeadMap' :: NetHeadMap -> [SGInput] -> STM ()
addToHeadMap' mapvar sgInputs = do
    currentHeads <- readTVar mapvar
    mTrace $ "curHeads" ++ show (IM.keys currentHeads)
    unsafeIOToSTM (foldM folder currentHeads sgInputs) >>= writeTVar mapvar
    currentHeads2 <- readTVar mapvar
    mTrace $ "curHeads(added)" ++ show (IM.keys currentHeads2)
  where
    folder !acc i   = (\(l,e) -> IM.insert l e acc) <$> mkDynInput i
    mkDynInput :: SGInput -> IO (Label, EInput)
    mkDynInput (SGInput t e) =
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
-- we convert the ChainM into a ModGraphM to update a frozen graph,
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
        doMergePrep = do
            dl <- runDyn
            prepareForMerge $ dl^.dlRemSet
            s <- get
            return (dl,s)
    (dirties2,final,(dirtyLog,finalGraph)) <- replacingRunningGraph rg doMergePrep
    let pushEvents = appEndo (dirtyLog^.dlEvents) []
        addNewHeads = addToHeadMap' (net^.nInputs)
                      $ appEndo (dirtyLog^.dlAddInp) []

        dirties = dirties2 <> dirtyLog^.dlChains
    addNewHeads
    knownInputs <- net^!nInputs.act readTVar

    let recompile :: Label -> EChain -> STM ()
        recompile lbl (EChain _ c) = IM.lookup lbl knownInputs^!_Just.act (
          \(EInput wk) -> wk^!act (unsafeIOToSTM .deRefWeak)._Just.act (
          \pushVar -> let cc = compileChain (unsafeCoerce c) id
                      in do mTrace $ showChainTree c
                            writeTVar pushVar $ runUpdates net . cc ))

        -- we only want to run the action for each node once.  For some reason
        -- I think we may have multiple occurrences of them.
        -- TODO: see if this step is really necessary.
        checkFireOnce :: IntSet -> FireOnce -> IO IntSet
        checkFireOnce acc fo
          | IntSet.member (fo^.label) acc = return acc
          | otherwise = IntSet.insert (fo^.label) acc <$ runFireOnce net fo

    mTrace $ "final graph chains:\n" ++ unlines (finalGraph^.dgHeads._Wrapped.traverse._Wrapped.to (\(EChain _ x) -> [showChainTree x]))
    mTrace "*** end ***"
    mapMOf_ (from dirtyChains.members)
        (\lbl -> finalGraph ^! dgHeads._Wrapped.to (IM.lookup lbl)._Just
              ._Wrapped.act (recompile lbl))
        dirties

    let curChains = atomically $ net^!nDynGraph.dgHeads.act readTVar.traverse.act (unsafeIOToSTM.deRefWeak)._Just.to (\(EChain _ x) -> [showChainTree x])
    return $ final >> void (foldM checkFireOnce mempty pushEvents) >> mTrace ("Current heads\n" ++ (unlines $ unsafePerformIO curChains))

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
                            & dgHeads._Wrapped .~ heads'w
                            & dgBehaviors._Wrapped .~ behs'w
            mutgraph = startBuildingGraph
                        & dgHeads._Wrapped .~ noMaybes heads'm
                        & dgBehaviors._Wrapped .~ noMaybes behs'm
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
                       in maybe (error $ "impulse <replacingRunningGraph>: missing MkWeak for " ++ show lbl)
                                (\w -> unMkWeak w t evictor)
                                mkw
            folder map' dirtyLbl = do
                    h' <- traverse (mkAWeakRef.runIdentity)
                             $ newg^.dgHeads._Wrapped.to (IM.lookup dirtyLbl)
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
                        $ newg^.fieldLens._Wrapped
                atomically $ g^!fieldLens.act (flip modifyTVar' (IM.union mb1))
        return $ mkWeakHeads >> mkWeakBs

-- This function takes the constructed BuildingDynGraph in ModGraphM's state
-- and merges it with the frozenMutGraph, putting the merged graph back into
-- the state.  This should only be called immediately before unfreezing the
-- state.
prepareForMerge :: ChainEdgeMap -> ModGraphM ()
prepareForMerge cem = do
    -- the initial, frozen graph.
    baseg <- view $ frozenMutGraph.dgHeads._Wrapped
    -- we need to prune the pre-existing graph.  The new chains should
    -- already be pruned though, so we can leave them be.
    let remSet = cem^.from chainEdgeMap.to (IM.keysSet)
        pruneEChain e@(EChain p c) = if not . IntSet.null . IntSet.intersection remSet $ c^.cPushSet'
            then (DirtyChains $ IntSet.singleton (c^.label), EChain p $ removeEdges cem c)
            else (mempty, e)
    let doAcc :: DirtyChains -> EChain -> (DirtyChains,EChain)
        doAcc !s e = pruneEChain e & _1 <>~ s
        (rmDirties, baseg') = mapAccumLOf (traverse._Wrapped) doAcc mempty baseg
    scribe dlChains rmDirties
    -- the built sub-graph to add
    newg  <- get
    newg' <- foldlMOf (dgHeads._Wrapped.traverse._Wrapped)
                (procNewHead $ newg^.dgBoundMap ) baseg' newg

    dgHeads._Wrapped.=newg'
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
              else IM.map (over _Wrapped f') runningGraph
                   <$ markDirties parentSet

boundSet :: BuildingDynGraph -> BoundarySet
boundSet g = g^.dgHeads._Wrapped.traverse._Wrapped.cBoundarySet

data Stepper =
    AllDone [IO ()]
  | NeedsIO UpdateStep UpdateBuilder

needsIO :: Stepper -> Bool
needsIO (NeedsIO _ _) = True
needsIO _ = False

runUpdates :: Network -> STM UpdateBuilder -> IO ()
runUpdates network doSteps = do
    let tm = network^.nTManager

    let stepBuilderIO :: UpdateBuilder -> IO ()
        stepBuilderIO ub = atomically (stepBuilder network ub) >>= \case
            AllDone finalSteps -> sequence_ finalSteps
            NeedsIO (DynMod akt) ub' -> do
              (chn,dynUb) <- akt
              updateFinalizers <- atomically $ dynUpdateGraph network chn
              ub'2 <- atomically dynUb
              stepBuilderIO $ ub' <> ub'2 & ubOutputs %~ (updateFinalizers:)
            NeedsIO _ _ -> error "<impulse>: stepBuilderIO: didn't get a DynMod!"

    maybeExclusive tm needsIO (doSteps >>= stepBuilder network) >>= \case
      (AllDone finalSteps, Nothing) -> sequence_ finalSteps
      (NeedsIO ioStep rest, Just ticket) -> do
          stepBuilderIO $ rest & modSteps %~ (ioStep:)
          commitExclusive tm ticket
      (AllDone _, Just _) -> error "<impulse> Got a ticket?"
      (NeedsIO _ _, Nothing) -> error "<impulse> needs a ticket!"

stepBuilder :: Network -> UpdateBuilder -> STM Stepper
stepBuilder network = go
  where
    go ub = case ub^.modSteps of
      (Mod m:steps) -> do
          cleanupActs <- dynUpdateGraph network m
          go $ ub & modSteps .~ steps & ubOutputs %~ (cleanupActs :)
      (step@(DynMod _):steps) -> return $ NeedsIO step $ ub & modSteps .~ steps
      [] -> case ub^.readSteps of
          (step:steps) -> do
              ub' <- step
              let outsF = case ub^.ubOutputs of
                            []  -> id
                            [x] -> ubOutputs %~ (x:)
                            xs  -> ubOutputs %~ (xs ++)
              go $ ub' & readSteps %~ (steps <>) & outsF
          [] -> return . AllDone $ ub^.ubOutputs

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
