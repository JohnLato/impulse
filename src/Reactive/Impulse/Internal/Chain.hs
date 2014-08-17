{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}

{-# OPTIONS_GHC -Wall #-}
-- The 'Chain' is the main runtime representation of a reactive network.
-- An input is connected to several chains, each of which is a series of
-- IO actions (pushes), culminating in either a 'reactimate' or updating
-- a Behavior.
-- All reactimate chains are performed in the order of the reactimate calls,
-- then all behavior updates are performed (in an arbitrary order).

module Reactive.Impulse.Internal.Chain (
  buildTopChains
, compileChain
, insertAt
, removeEdges
) where

import Reactive.Impulse.Core
import Reactive.Impulse.Internal.Types
import Reactive.Impulse.Internal.Weak

import Control.Applicative
import Control.Concurrent.STM
import Control.Lens
import Control.Monad.Identity
import Control.Monad.State (runStateT)
import Control.Monad.RWS

import Data.Foldable (foldl')
import qualified Data.IntMap as IM
import qualified Data.IntSet as IntSet
import Data.IntSet.Lens

import System.Mem.StableName
import System.Mem.Weak
import Unsafe.Coerce
import GHC.Conc.Sync (unsafeIOToSTM)

-----------------------------------------------------------

singleton :: Chain r a -> ChainNode (Chain r a)
singleton c = ChainNode [c] (IntSet.singleton $ c^.label)

eSingleton :: EChain -> ChainNode (Chain (IO ()) a)
eSingleton e = singleton $ e^.from echain

pushNode :: (r ~ IO ()) => ChainNode (Chain r a) -> Label -> EChain -> ChainNode (Chain r a)
pushNode cn parentLbl ec
    | IntSet.member parentLbl (cn^.cnPushSet) =
        fmap (insertAt parentLbl ec) $
            over cnPushSet (IntSet.insert (ec^.label)) cn
    | otherwise = cn

insertAt :: (r ~ IO ()) => Label -> EChain -> Chain r a -> Chain r a
insertAt parentLbl eChain chain = case chain of
    (CEvent lbl cn)
      | parentLbl == lbl -> CEvent lbl (cn <> eSingleton eChain)
      | otherwise -> CEvent lbl (pushNode cn parentLbl eChain)
    (CMap lbl f cn)
      | parentLbl == lbl -> CMap lbl f (cn <> eSingleton eChain)
      | otherwise -> CMap lbl f (pushNode cn parentLbl eChain)
    (CFilt lbl p cn)
      | parentLbl == lbl -> CFilt lbl p (cn <> eSingleton eChain)
      | otherwise -> CFilt lbl p (pushNode cn parentLbl eChain)
    (CSwchE lbl prevSet a cn)
      | parentLbl == lbl -> CSwchE lbl prevSet a (cn <> eSingleton eChain)
      | otherwise -> CSwchE lbl prevSet a (pushNode cn parentLbl eChain)
    (CDyn lbl cn)
      | parentLbl == lbl -> CDyn lbl (cn <> eSingleton eChain)
      | otherwise -> CDyn lbl (pushNode cn parentLbl eChain)
    (CJoin lbl prevSet cn)
      | parentLbl == lbl -> CJoin lbl prevSet (cn <> eSingleton eChain)
      | otherwise -> CJoin lbl prevSet (pushNode cn parentLbl eChain)
    (COut lbl)
      | parentLbl == lbl ->
          error $ "impulse <insertAt>: internal error, to COut " ++ show lbl
      | otherwise -> chain
    (CAcc lbl _)
      | parentLbl == lbl ->
          error $ "impulse <insertAt>: internal error, to CAcc " ++ show lbl
      | otherwise -> chain
    (CApply lbl beh cn)
      | parentLbl == lbl -> CApply lbl beh (cn <> eSingleton eChain)
      | otherwise -> CApply lbl beh (pushNode cn parentLbl eChain)
    (CSwch lbl _)
      | parentLbl == lbl ->
          error $ "impulse <insertAt>: internal error, to CSwch " ++ show lbl
      | otherwise -> chain

-- True if the labelled chain is referenced by this chain.
containsChain :: Chain r a -> Label -> Bool
containsChain c t = t == c^.label
    || anyOf (cPushSet._Just) (IntSet.member t) c

removeEdges :: ChainEdgeMap -> Chain r a -> Chain r a
removeEdges chainMap' chain = f chain
  where
   chainMap = chainMap'^.from chainEdgeMap
   fromSet = IM.keysSet chainMap
   toSet fromLbl = IM.lookup fromLbl chainMap^._Just

   pruneNode :: Label -> ChainNode (Chain r x) -> ChainNode (Chain r x)
   pruneNode fromLbl cn
      -- pushing from fromSet, so we remove all children that match toSet
      -- and descend into remaining children.
      | IntSet.member fromLbl fromSet = alterChildren cn
          (map f . filter (\x -> IntSet.notMember (x^.label) (toSet fromLbl)))
      | not . IntSet.null $ cn^.cnPushSet.to (IntSet.intersection fromSet) =
          alterChildren cn (map f)
      | otherwise = cn

   f :: Chain r x -> Chain r x
   f c = case c of
    (CEvent lbl cn)  -> CEvent lbl (pruneNode lbl cn)
    (CMap lbl mf cn) -> CMap lbl mf (pruneNode lbl cn)
    (CSwchE lbl prevSet a cn) ->
          CSwchE lbl prevSet a (pruneNode lbl cn)
    (CApply lbl beh cn) -> CApply lbl beh (pruneNode lbl cn)
    _  -> c

makeCBehavior :: TVar a -> CBehavior a
makeCBehavior ref = PushCB ref

readCB :: CBehavior a -> STM a
readCB (ReadCB x) = x
readCB (PushCB x) = readTVar x
readCB (SwchCB (CBSwitch r))   = readTVar r >>= readCB

makeCBSwitch :: TVar a -> CBSwitch a
makeCBSwitch = CBSwitch

-----------------------------------------------------------

-- Add a new top-level chain to a DynGraph
addHead :: EChain -> MkWeak -> BuildingDynGraph -> BuildingDynGraph
addHead e@(EChain _ c) mkw g = g
  & (dgHeads._Wrapped)%~(IM.insert lbl $ Identity e)
  & dgMkWeaks%~(IM.insert lbl mkw)
  & dgChainCache<>~pushSet'
  & dgChainHeads<>~IM.fromSet (const lbl) pushSet'
 where
  lbl = e^.label
  pushSet' = maybe (IntSet.singleton lbl) (IntSet.insert lbl) (c^.cPushSet)

-- removeHead only removed the head reference for a chain, it does
-- not remove it from the ChainCache (set of all referenced chains)
-- nor does it remove targets from ChainHeads (map of chain -> head)
removeHead :: Label -> BuildingDynGraph -> BuildingDynGraph
removeHead lbl g
  | getAny permHeads = g
  | otherwise = g
      & (dgHeads._Wrapped)%~(IM.delete lbl)
      & dgMkWeaks%~(IM.delete lbl)
 where
  permHeads =
      g^.dgHeads._Wrapped.to (IM.lookup lbl)
      . _Just._Wrapped.permHead._Unwrapping Any

-- Add a chain under the given label.
addChainTo :: EChain -> Label -> BuildingDynGraph -> BuildingDynGraph
addChainTo eChain@(EChain _ c) parentLbl dg = dg
      & over (dgHeads._Wrapped) (IM.adjust (over _Wrapped f') parentHead)
      & dgChainCache<>~ pushSet'
      & dgChainHeads<>~ IM.fromSet (const parentHead) pushSet'
    where
      f' (EChain p ec) = EChain p $ insertAt parentLbl eChain ec
      childLbl = eChain^.label
      parentHead = maybe (error "impulse: addChainTo: parent not found!")
                         id $ dg^.dgChainHeads.to (IM.lookup parentLbl)
      pushSet' = maybe (IntSet.singleton childLbl)
                  (IntSet.insert childLbl) (c^.cPushSet)

chainExists :: Label -> BuildingDynGraph -> Bool
chainExists needle dg = dg ^. dgChainCache . to (IntSet.member needle)

getChain :: Label -> BuildingDynGraph -> Maybe EChain
getChain needle dg =
    getFirst $ foldMapOf (dgChainHeads.to (IM.lookup needle)._Just
                         .to (\lbl -> dg^.dgHeads._Wrapped.to (IM.lookup lbl))
                         ._Just._Wrapped) stepper' dg
  where
    stepper' :: EChain -> First EChain
    stepper' (EChain p c) = stepper p c

    stepper :: PermHead -> Chain (IO ()) x -> First EChain
    stepper p c
        | needle == c^.label = First . Just $ EChain p c
        | otherwise = stepChain p c

    stepChain :: PermHead -> Chain (IO ()) x -> First EChain
    stepChain p c | c^.label == needle = First . Just $ EChain p c
    stepChain p c@(CEvent _ n)
        | containsChain c needle = foldMapOf (cnChildren.folded) (stepper p) n
    stepChain p c@(CMap _ _ n)
        | containsChain c needle = foldMapOf (cnChildren.folded) (stepper p) n
    stepChain p c@(CApply _ _ n)
        | containsChain c needle = foldMapOf (cnChildren.folded) (stepper p) n
    stepChain p c@(CSwchE _ _ _ n)
        | containsChain c needle = foldMapOf (cnChildren.folded) (stepper p) n
    stepChain _ _ = mempty

-----------------------------------------------------------

addBehavior :: EBehavior -> ChainM ()
addBehavior e = dgBehaviors._Wrapped %= IM.insert (e^.label) (Identity e)

lookupBehavior :: Label -> ChainM (Maybe EBehavior)
lookupBehavior lbl = (fmap.fmap) runIdentity
    $ use (dgBehaviors._Wrapped.to (IM.lookup lbl))

-----------------------------------------------------
-- dynamic stuff

-- Create an event that fires when a Behavior is updated.
-- the relative times are undefined, so this shouldn't be exposed!
onChangedB :: Behavior a -> Event ()
onChangedB (BAcc _ _ e) = () <$ e
onChangedB (BMap _ _ b) = onChangedB b
onChangedB (BPure _ _)  = mempty
onChangedB (BApp _ b1 b2) = onChangedB b1 <> onChangedB b2
onChangedB (BSwch _ _ e)  = () <$ e

-----------------------------------------------------

buildTopChains :: [ Event (IO ()) ] -> ChainM ()
buildTopChains = buildChains

-- build all chains for a given set of output Events.
buildChains :: [ Event (IO ()) ] -> ChainM ()
buildChains = mapM_ addChain'
  where
    guardBound lbl chainAction = do
        boundary <- view (from boundarySet)
        when (not $ IntSet.member lbl boundary) chainAction
    addChain' :: Event (IO ()) -> ChainM ()
    addChain' evt@(EOut lbl prev) = guardBound lbl $ do
            let chn = COut lbl :: Chain (IO ()) (IO ())
                mkw = MkWeak $ mkWeak evt
            modify $ addHead (EChain False chn) mkw
            addChain lbl prev
    addChain' _ = error "impulse <buildChains>: got non-terminal with no child info"

addBound :: Label -> Label -> Event k -> ChainM () -> ChainM ()
addBound childLbl thisLbl evt chainAction = do
    boundary <- view $ from boundarySet
    if IntSet.member thisLbl boundary
      then do
            dgBoundMap.from boundaryMap %=
              IM.insertWith (<>) childLbl (IntSet.singleton thisLbl)
            tracebackMkWeakHeads evt
      else chainAction


-- if the chain already exists, we don't need to add it, but we do
-- need to add the ultimate heads into the MkWeak collection
addChain :: Label -> Event k -> ChainM ()
addChain _ (EOut _ _) = error "impulse <addChain>: got a non-terminal EOut"
addChain childLbl evt@(EIn lbl)  = addBound childLbl lbl evt $ do
    mTrace $ "EIn " ++ show lbl
    void $ addChains False childLbl lbl evt (CEvent lbl)
addChain childLbl evt@(ENull lbl prevE)  = addBound childLbl lbl evt $ do
    mTrace $ "ENull " ++ show lbl
    added <- addChains False childLbl lbl evt (CEvent lbl)
    when added (addChain lbl prevE)
addChain childLbl evt@(EMap lbl f prevE) = addBound childLbl lbl evt $ do
    mTrace $ "EMap " ++ show lbl
    added <- addChains False childLbl lbl evt (CMap lbl f)
    when added (addChain lbl prevE)
addChain childLbl evt@(EFilt lbl p prevE) = addBound childLbl lbl evt $ do
    mTrace $ "EFilt " ++ show lbl
    added <- addChains False childLbl lbl evt (CFilt lbl p)
    when added (addChain lbl prevE)
addChain childLbl evt@(EUnion lbl prev1 prev2) = addBound childLbl lbl evt $ do
    mTrace $ "EUnion " ++ show lbl
    added <- addChains False childLbl lbl evt (CEvent lbl)
    when added (addChain lbl prev1 >> addChain lbl prev2)
addChain childLbl evt@(EApply lbl prevE beh) = addBound childLbl lbl evt $ do
    mTrace $ "EApply " ++ show lbl
    cbeh  <- makeBehavior beh
    added <- addChains False childLbl lbl evt (CApply lbl cbeh)
    when added (addChain lbl prevE)
addChain childLbl evt@(ESwch lbl beh) = addBound childLbl lbl evt $ do
    mTrace $ "ESwch " ++ show lbl
    cbeh  <- makeBehavior beh --CBehavior (Event a)
    let onChangedE = onChangedB beh
    prevSet <- lift $ newTVar emptyPrevSwchRef
    added <- addChains True childLbl lbl evt (CSwchE lbl prevSet cbeh)
    scribe dlEvents $ Endo (FireOnce lbl () :)
    when added $ addChain lbl onChangedE
addChain childLbl evt@(EJoin lbl prevE) = addBound childLbl lbl evt $ do
    mTrace $ "EJoin " ++ show lbl
    prevSet <- lift $ newTVar emptyPrevSwchRef
    added <- addChains True childLbl lbl evt (CJoin lbl prevSet)
    when added (addChain lbl prevE)
addChain childLbl evt@(EDyn lbl prevE) = addBound childLbl lbl evt $ do
    mTrace $ "EDyn " ++ show lbl
    added <- addChains False childLbl lbl evt (CDyn lbl)
    when added (addChain lbl prevE)

tracebackMkWeakHeads :: Event k -> ChainM ()
tracebackMkWeakHeads e = case e of
    EIn _ -> dgMkWeaks %= (IM.insert (e^.label) $ MkWeak $ mkWeak e)
    EOut _ e'      -> tracebackMkWeakHeads e'
    ENull _ e'     -> tracebackMkWeakHeads e'
    EMap _ _ e'    -> tracebackMkWeakHeads e'
    EFilt _ _ e'   -> tracebackMkWeakHeads e'
    EUnion _ e1 e2 -> tracebackMkWeakHeads e1 >> tracebackMkWeakHeads e2
    EApply _ e' _  -> tracebackMkWeakHeads e'
    ESwch _ _      -> return ()
    EJoin _ e'     -> tracebackMkWeakHeads e'
    EDyn _ e'      -> tracebackMkWeakHeads e'

addChains
    :: (r ~ IO ())
    => PermHead
    -> Label
    -> Label
    -> Event k
    -> (ChainNode (Chain r a) -> Chain r b)
    -> ChainM Bool  -- True if the chain was added
addChains p childLbl lbl evt constr = do
    dg <- get
    let Just childChain = getChain childLbl dg
        eChain = EChain p (constr $ eSingleton childChain)
        mkw = MkWeak $ mkWeak evt
    if chainExists lbl dg
        then mTrace ("adding " ++ show childLbl ++ " to " ++ show lbl)
             >> False <$ put (addChainTo childChain lbl dg)
        else True  <$ put (removeHead childLbl $ addHead eChain mkw dg)

makeBehavior :: Behavior k -> ChainM (CBehavior k)
makeBehavior (BAcc lbl a0 prevE) = lookupBehavior lbl >>= \case
    Just (EBehavior lbl' beh)
        | lbl == lbl' -> return (unsafeCoerce beh)
        | otherwise -> error $ "impulse <makeBehavior>: labels don't match for BAcc!"
    Nothing -> do
        mTrace $ "BAcc " ++ show lbl
        tvar <- lift $ newTVar a0
        -- BAcc is both a terminal push action and an initial pull
        -- so it goes in both chain and behavior maps
        let cbeh = makeCBehavior tvar
            mkw = MkWeak $ mkWeakTVarKey tvar
        modify $ addHead (EChain False $ CAcc lbl cbeh) mkw
        addBehavior $ EBehavior lbl cbeh
        -- the pushing event needs to have this child added
        cbeh <$ addChain lbl prevE
makeBehavior (BPure _l a) = return (ReadCB (return a))
makeBehavior (BMap lbl f prevB) = lookupBehavior lbl >>= \case
    Just (EBehavior lbl' beh)
        | lbl == lbl' -> return (unsafeCoerce beh)
        | otherwise -> error $ "impulse <makeBehavior>: labels don't match for BMap!"
    Nothing -> do
        mTrace $ "BMap " ++ show lbl
        pRead <- readCB <$> makeBehavior prevB
        -- always force stuff before calling makeStableName
        !p0 <- lift $ pRead
        cache <- lift $ do
            stn <- unsafeIOToSTM $ makeStableName p0
            newTVar (stn,f p0)
        let cbeh = ReadCB cRead
            cRead = do
                (stn,c) <- readTVar cache
                !p   <- pRead
                stn' <- unsafeIOToSTM $ makeStableName p
                if stn == stn'
                    then return c
                    else let c' = (f p)
                        in writeTVar cache (stn',c') >> return c'
        addBehavior $ EBehavior lbl cbeh
        return cbeh
makeBehavior (BApp lbl fB prevB) = lookupBehavior lbl >>= \case
    Just (EBehavior lbl' cbeh)
        | lbl == lbl' -> return $ unsafeCoerce cbeh
        | otherwise -> error "impulse <makeBehavior>: labels don't match for BApp"
    Nothing -> do
        mTrace $ "BApp " ++ show lbl
        pRead <- readCB <$> makeBehavior prevB
        fRead <- readCB <$> makeBehavior fB
        -- always force stuff before calling makeStableName
        !p0 <- lift $ pRead
        !f0 <- lift $ fRead
        cache <- lift $ do
            (stn1,stn2) <- unsafeIOToSTM
                $ (,) <$> makeStableName f0 <*> makeStableName p0
            newTVar (stn1,stn2,f0 p0)
        let cbeh = ReadCB cRead
            cRead = do
                (stn1,stn2,c) <- readTVar cache
                !p   <- pRead
                !f   <- fRead
                (stn1',stn2') <- unsafeIOToSTM
                    $ (,) <$> makeStableName f <*> makeStableName p
                if stn1 == stn1' && stn2 == stn2'
                    then return c
                    else let c' = (f p)
                        in writeTVar cache (stn1',stn2',c') >> return c'
        addBehavior $ EBehavior lbl cbeh
        return cbeh
makeBehavior (BSwch lbl b prevE) = lookupBehavior lbl >>= \case
    Just (EBehavior lbl' beh)
        | lbl == lbl' -> return (unsafeCoerce beh)
        | otherwise -> error $ "impulse <makeBehavior>: labels don't match for BSwch!"
    Nothing -> do
        mTrace $ "BSwch " ++ show lbl
        b0  <- makeBehavior b
        tvar <- lift $ newTVar b0
        let cbs  = makeCBSwitch tvar
            cbeh = SwchCB cbs
            mkw  = MkWeak $ mkWeakTVarKey tvar
        modify $ addHead (EChain False $ CSwch lbl cbs) mkw
        addBehavior $ EBehavior lbl cbeh
        cbeh <$ addChain lbl prevE

-----------------------------------------------------

-- Compile a Chain.
-- The CompiledChain takes two inputs, the final sink and a value.
-- Performs all real terminal actions and returns an action to be
-- performed afterwards (updating behaviors)

compileChain :: (r ~ IO ()) => Chain r a -> CompiledChain r a
compileChain (CEvent _ next) = compileNode next
compileChain (CMap _ f next) =
    let !next' = compileNode next
    in \sink -> next' sink . f

compileChain (CFilt _ p next) =
    let !next' = compileNode next
    in \sink -> maybe (return []) (next' sink) . p

compileChain (COut _) =
    \sink a -> return [Norm (return (sink a))]
compileChain (CAcc _ (PushCB ref)) =
    const $ return . pure . Norm . (return () <$) . modifyTVar' ref

compileChain (CAcc _ _) =
    error "impulse <compileChain>: attempt to accumulate to non-accumulating behavior!"
compileChain (CApply _ cb next) =
    let !next'  = compileNode next
        !apReader = atomically $ readCB cb
    in \sink a -> do
        f <- apReader
        next' sink $! f a

-- updating a dynamic behavior
compileChain (CSwch _ (CBSwitch ref)) =
    \_sink newB -> do
        let actStep = makeBehavior newB >>= lift . writeTVar ref
        return [Mod actStep]

compileChain (CDyn _ next) =
    \sink newSGen -> do
        (a,sgstate) <- runStateT newSGen mempty
        return [DynMod (actStep sgstate) (next' sink a)]
    where
      !next'  = compileNode next
      actStep sgstate = do
          buildTopChains (sgstate^.outputs)
          scribe dlAddInp $ Endo ((sgstate^.inputs) ++)
          scribe (dlChains . from dirtyChains) $ setOf (inputs.traverse.label) sgstate

compileChain (CSwchE _ prevSetRef eventB cn) = 
    \_sink _ -> return [Mod actStep]
    where
      tmpHead e = IM.insertWith (const id) (e^.label) $ Identity e
      actStep = do
          -- This should be the way we set up the graph.
          -- onChangedE -> CSwchE
          -- eventFromBehavior ->  CSwchE children

          -- First we remove the old chains correspondening to the prev. edges
          -- into CSwchE children.  We can set the new refs now...
          let pushSet = cn^.cnChildren.folded.label.to (IntSet.singleton)
          (newE,pVals) <- lift $ do
              newE    <- readCB eventB
              pVals <- readTVar prevSetRef
              writeTVar prevSetRef $ PrevSwchRef
                { _psrEdgeMap = simpleEdgeMap (newE^.label) pushSet
                , _psrMkWeaks = tracebackMkWeakHeads newE
                }
              return (newE, pVals)
          let prevSet = pVals^.psrEdgeMap
          pVals^.psrMkWeaks
          dgHeads._Wrapped.traverse._Wrapped %= \(EChain p c) ->
              EChain p $ removeEdges prevSet c
          tell $ mempty
                  & dlChains .~ (prevSet^.from chainEdgeMap.to IM.keysSet.dirtyChains)
                  & dlRemSet .~ prevSet

          -- after the prevs are removed, we add the newly selected chain
          -- as a parent to each of the children.  If any of the children don't
          -- exist, add them as tmpHeads (they'll get removed+extended soon)
          -- TODO: this traverses the pushset a few times, which might be bad.
          -- Although I doubt it'll ever be large, we could get it down to
          -- a single traversal somehow.
          g <- get
          let missingChains = cn^.cnChildren.folded.to
                  (\c -> let l = c^.label
                         in if chainExists l g then mempty else IM.singleton l c)
          dgHeads._Wrapped %= \im ->
            foldrOf (folded.to (EChain False)) tmpHead im missingChains
          pushSet^!members.act (flip addChain newE)

compileChain (CJoin _ prevSetRef cn) =
    \sink newE -> return [Mod $ actStep newE]
    where
      tmpHead e = IM.insertWith (const id) (e^.label) $ Identity e
      actStep newE = do
          -- see notes for CSwchE
          let pushSet = cn^.cnChildren.folded.label.to (IntSet.singleton)
          (newE,pVals) <- lift $ do
              pVals <- readTVar prevSetRef
              writeTVar prevSetRef $ PrevSwchRef
                { _psrEdgeMap = simpleEdgeMap (newE^.label) pushSet
                , _psrMkWeaks = tracebackMkWeakHeads newE
                }
              return (newE, pVals)
          let prevSet = pVals^.psrEdgeMap
          pVals^.psrMkWeaks
          dgHeads._Wrapped.traverse._Wrapped %= \(EChain p c) ->
              EChain p $ removeEdges prevSet c
          tell $ mempty
                  & dlChains .~ (prevSet^.from chainEdgeMap.to IM.keysSet.dirtyChains)
                  & dlRemSet .~ prevSet

          g <- get
          let missingChains = cn^.cnChildren.folded.to
                  (\c -> let l = c^.label
                         in if chainExists l g then mempty else IM.singleton l c)
          dgHeads._Wrapped %= \im ->
            foldrOf (folded.to (EChain False)) tmpHead im missingChains
          pushSet^!members.act (flip addChain newE)

compileNode :: (r ~ IO ()) => ChainNode (Chain r a) -> CompiledChain r a
compileNode cn =
    case map compileChain (cn^.cnChildren) of
        [] -> \_ _ -> return []
        [next] -> next
        nexts  -> \sink a -> concat <$> mapM (\f -> f sink a) nexts
