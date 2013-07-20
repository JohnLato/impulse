{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE RecursiveDo #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE ViewPatterns #-}

{-# OPTIONS_GHC -Wall #-}
-- The 'Chain' is the main runtime representation of a reactive network.
-- An input is connected to several chains, each of which is a series of
-- IO actions (pushes), culminating in either a 'reactimate' or updating
-- a Behavior.
-- All reactimate chains are performed in the order of the reactimate calls,
-- then all behavior updates are performed (in an arbitrary order).

module Reactive.Impulse.Chain (
  DynGraph (..)
, emptyDynGraph
, buildTopChains
, EChain (..)
, chainLbl
, compileChain
, getChain
) where

import Reactive.Impulse.Core

import Control.Applicative
import Control.Monad.Identity
import Control.Monad.RWS
import Control.Newtype

import Data.Foldable (foldMap, foldl')
import Data.IORef
import Data.IntMap (IntMap)
import qualified Data.IntMap as IM
import qualified Data.IntSet as IntSet
import Data.Monoid

import System.Mem.StableName
import System.Mem.Weak
import Unsafe.Coerce

-----------------------------------------------------------

data FChain f r a where
    CEvent :: Label -> f (FChain f r a) -> FChain f r a
    CMap   :: Label -> (a -> b)  -> f (FChain f r b) -> FChain f r a
    COut   :: Label -> FChain f r r
    CAcc   :: Label -> CBehavior a -> FChain f r (a->a)
    CApply :: Label -> CBehavior (a -> b) -> f (FChain f r b) -> FChain f r a
    CDynB  :: Label -> CBSwitch (CBehavior a) -> FChain f r (Behavior a)
-- not sure that I actually need the functor param.  Originally wanted
-- to switch between ChainNode and Identity, but now that's no longer
-- necessary

type Chain r a = FChain ChainNode r a

chainLbl :: Chain r a -> Label
chainLbl (CEvent lbl _) = lbl
chainLbl (CMap lbl _ _) = lbl
chainLbl (COut lbl)     = lbl
chainLbl (CAcc lbl _)   = lbl
chainLbl (CApply lbl _ _) = lbl
chainLbl (CDynB lbl _)    = lbl

data ChainNode t = ChainNode
    { cnChildren :: [ t ]
    , cnPushSet   :: ChainSet
    } deriving Functor

instance Monoid (ChainNode t) where
    mempty = ChainNode [] IntSet.empty
    ChainNode l1 l2 `mappend` ChainNode r1 r2 =
      ChainNode (l1 <> r1) (l2 `IntSet.union` r2)

type ChainSet = IntSet.IntSet

singleton :: Label -> Chain r a -> ChainNode (Chain r a)
singleton lbl c = ChainNode [c] (IntSet.singleton lbl)

eSingleton :: EChain -> ChainNode (Chain r a)
eSingleton (EChain c) = singleton (chainLbl c) (unsafeCoerce c)

pushNode :: ChainNode (Chain r a) -> Label -> EChain -> ChainNode (Chain r a)
pushNode cn@(ChainNode {..}) parentLbl ec
    | IntSet.member parentLbl cnPushSet =
        let cnPushSet' = IntSet.insert (eLbl ec) cnPushSet 
        in fmap (insertAt parentLbl ec) cn {cnPushSet = cnPushSet'}
    | otherwise = cn

insertAt :: Label -> EChain -> Chain r a -> Chain r a
insertAt parentLbl echain chain = case chain of
    (CEvent lbl cn)
      | parentLbl == lbl -> CEvent lbl (cn <> eSingleton echain)
      | otherwise -> CEvent lbl (pushNode cn parentLbl echain)
    (CMap lbl f cn)
      | parentLbl == lbl -> CMap lbl f (cn <> eSingleton echain)
      | otherwise -> CMap lbl f (pushNode cn parentLbl echain)
    (COut lbl)
      | parentLbl == lbl ->
          error $ "Impulse: internal error, insertAt to COut" ++ show lbl
      | otherwise -> chain
    (CAcc lbl _)
      | parentLbl == lbl ->
          error $ "Impulse: internal error, insertAt to CAcc" ++ show lbl
      | otherwise -> chain
    (CApply lbl beh cn)
      | parentLbl == lbl -> CApply lbl beh (cn <> eSingleton echain)
      | otherwise -> CApply lbl beh (pushNode cn parentLbl echain)
    (CDynB lbl _)
      | parentLbl == lbl ->
          error $ "Impulse: internal error, insertAt to CDynB" ++ show lbl
      | otherwise -> chain

-- True if the labelled chain is referenced by this chain.
containsChain :: Chain r a -> Label -> Bool
containsChain (CEvent l   ChainNode{..}) t = t == l || IntSet.member t cnPushSet
containsChain (CMap l _   ChainNode{..}) t = t == l || IntSet.member t cnPushSet
containsChain (CApply l _ ChainNode{..}) t = t == l || IntSet.member t cnPushSet
containsChain (chainLbl -> l) t = t == l

-- A CBehavior is the representation of a Behavior within a Chain.
data CBehavior a =
    ReadCB (IO a)
  | PushCB (IO a) ((a -> a) -> IO ())
  | SwchCB {-# UNPACK #-} !(CBSwitch (CBehavior a))

-- only used for dynamic network switching
data CBSwitch a = CBSwitch (IO a) (a -> IO ())

makeCBehavior :: IORef a -> CBehavior a
makeCBehavior ref = PushCB (readIORef ref) modd
  where
    modd f = atomicModifyIORef' ref (\l -> let a' = f l in (a',a')) >>= (`seq` return ())

readCB :: CBehavior a -> IO a
readCB (ReadCB x)   = x
readCB (PushCB x _) = x
readCB (SwchCB (CBSwitch r _))   = r >>= readCB

makeCBSwitch :: IORef a -> CBSwitch a
makeCBSwitch ref = CBSwitch (readIORef ref) modd
  where
    modd !x = atomicWriteIORef ref x

-- wrap chains to put them in a map
data EChain where
    EChain :: Chain r a -> EChain

data EBehavior where
    EBehavior :: Label -> CBehavior a -> EBehavior

eLbl :: EChain -> Label
eLbl (EChain c ) = chainLbl c
-----------------------------------------------------------

-- a DynGraph is a collection of chains that can be compiled
-- and/or executed.  It is basically a map of chain heads.

data DynGraph = DynGraph
  { dgHeads     :: IntMap EChain
  , dgBehaviors :: IntMap EBehavior
  , dgBoundsMap :: IntMap Label
  -- map from heads to their prev label
  -- The boundaryMap is not used for all heads, only when dynamically switching
  -- to already-existing heads.
  , dgBoundary  :: ChainSet
  , dgDynNodes  :: IntMap (Weak DynNodeX)
  }

type DynNodeX = IORef [DynHeadX]

data DynHeadX where
  DynHeadX :: IORef (Label, a -> IO ()) -> DynHeadX

emptyDynGraph :: DynGraph
emptyDynGraph = DynGraph IM.empty IM.empty IM.empty IntSet.empty IM.empty

-- Add a new top-level chain to a DynGraph
addHead :: EChain -> DynGraph -> DynGraph
addHead e dg =
    dg { dgHeads = IM.insert (eLbl e) e $ dgHeads dg }

removeHead :: Label -> DynGraph -> DynGraph
removeHead lbl dg = dg { dgHeads = IM.delete lbl $ dgHeads dg }

-- Add a chain under the given label.
addChainTo :: EChain -> Label -> DynGraph -> DynGraph
addChainTo echain parentLbl dg = dg
    { dgHeads = IM.map f $ dgHeads dg }
    where
      f (EChain ec) = EChain $ insertAt parentLbl echain ec

addBoundary :: Label -> Label -> DynGraph -> DynGraph
addBoundary thisLbl childLbl dg = dg
    { dgBoundsMap = IM.insert childLbl thisLbl (dgBoundsMap dg) }

chainExists :: Label -> DynGraph -> Bool
chainExists needle DynGraph{..} = any f $ IM.elems dgHeads
  where
    f (EChain c) = containsChain c needle

getChain :: Label -> DynGraph -> Maybe EChain
getChain target = stepper' . IM.elems . dgHeads
  where
    stepper :: [Chain r x] -> Maybe EChain
    stepper = ala First (foldMap . (. stepChain))
    stepper' = ala First (foldMap . (. getIt))
    getIt e@(EChain c)
        | target == chainLbl c = Just e
        | otherwise     = stepChain c
    stepChain :: Chain r x -> Maybe EChain
    stepChain c | chainLbl c == target = Just $ EChain c
    stepChain c@(CEvent _ n) = do
        guard (containsChain c target)
        stepper $ cnChildren n
    stepChain c@(CMap _ _ n) = do
        guard (containsChain c target)
        stepper $ cnChildren n
    stepChain c@(CApply _ _ n) = do
        guard (containsChain c target)
        stepper $ cnChildren n
    stepChain _ = Nothing

-----------------------------------------------------------

-- The ChainM monad keeps track of a DynGraph as it's being constructed.
type ChainM w = RWST () w DynGraph IO

type DynW = ()

addBehavior :: Monoid w => EBehavior -> ChainM w ()
addBehavior e@(EBehavior lbl _) = modify $
    \dg -> dg { dgBehaviors = IM.insert lbl e $ dgBehaviors dg }

lookupBehavior :: Monoid w => Label -> ChainM w (Maybe EBehavior)
lookupBehavior lbl = IM.lookup lbl . dgBehaviors <$> get

-----------------------------------------------------

buildTopChains :: [ Event (IO ()) ] => ChainM () ()
buildTopChains = buildChains

-- build all chains for a given set of output Events.
buildChains :: forall w. Monoid w => [ Event (IO ()) ] -> ChainM w ()
buildChains = mapM_ addChain'
  where
    guardBound lbl act = do
        boundary <- dgBoundary <$> get
        when (not $ IntSet.member lbl boundary) act
    addChain' (EOut lbl prev) = guardBound lbl $ do
            let chn = COut lbl :: Chain (IO ()) (IO ())
            modify $ addHead (EChain chn)
            addChain lbl prev
    addChain' _ = error "buildChains: got non-terminal with no child info"

addBound :: Monoid w => Label -> Label -> ChainM w () -> ChainM w ()
addBound childLbl thisLbl act = do
    boundary <- dgBoundary <$> get
    if IntSet.member thisLbl boundary
      then modify $ addBoundary thisLbl childLbl
      else act

addChain :: Monoid w => Label -> Event k -> ChainM w ()
addChain _ (EOut _ _) = error "buildChains: got a non-terminal EOut"
addChain childLbl (EIn lbl)  = addBound childLbl lbl $ do
    mTrace $ "EIn " ++ show lbl
    void $ addChains childLbl lbl (CEvent lbl)
addChain childLbl (ENull lbl prevE)  = addBound childLbl lbl $ do
    mTrace $ "ENull " ++ show lbl
    added <- addChains childLbl lbl (CEvent lbl)
    when added $ addChain lbl prevE
addChain childLbl (EMap lbl f prevE) = addBound childLbl lbl $ do
    mTrace $ "EMap " ++ show lbl
    added <- addChains childLbl lbl (CMap lbl f)
    when added $ addChain lbl prevE
addChain childLbl (EUnion lbl prev1 prev2) = addBound childLbl lbl $ do
    mTrace $ "EUnion " ++ show lbl
    added <- addChains childLbl lbl (CEvent lbl)
    when added $ addChain lbl prev1 >> addChain lbl prev2
addChain childLbl (EApply lbl prevE beh) = addBound childLbl lbl $ do
    mTrace $ "EApply " ++ show lbl
    cbeh  <- makeBehavior beh
    added <- addChains childLbl lbl (CApply lbl cbeh)
    when added $ addChain lbl prevE

addChains
    :: Monoid w
    => Label
    -> Label
    -> (ChainNode (Chain r a) -> Chain r b)
    -> ChainM w Bool  -- True if the chain was added
addChains childLbl lbl constr = do
    dg <- get
    let Just childChain = getChain childLbl dg
        echain = EChain (constr $ eSingleton childChain)
    if chainExists lbl dg
        then mTrace ("adding " ++ show childLbl ++ " to " ++ show lbl) >> False <$ put (addChainTo childChain lbl dg)
        else True  <$ put (removeHead childLbl $ addHead echain dg)

makeBehavior :: forall w k. Monoid w => Behavior k -> ChainM w (CBehavior k)
makeBehavior (BAcc lbl a0 prevE) = lookupBehavior lbl >>= \case
    Just (EBehavior lbl' beh)
        | lbl == lbl' -> return (unsafeCoerce beh)
        | otherwise -> error $ "buildChains: labels don't match for BAcc!"
    Nothing -> do
        mTrace $ "BAcc " ++ show lbl
        cbeh <- liftIO $ makeCBehavior <$> newIORef a0
        -- BAcc is both a terminal push action and an initial pull
        -- so it goes in both chain and behavior maps
        modify $ addHead (EChain $ CAcc lbl cbeh)
        addBehavior $ EBehavior lbl cbeh
        -- the pushing event needs to have this child added
        cbeh <$ addChain lbl prevE
makeBehavior (BPure _l a) = return (ReadCB (return a))
makeBehavior (BMap lbl f prevB) = lookupBehavior lbl >>= \case
    Just (EBehavior lbl' beh)
        | lbl == lbl' -> return (unsafeCoerce beh)
        | otherwise -> error $ "buildChains: labels don't match for BMap!"
    Nothing -> do
        mTrace $ "BMap " ++ show lbl
        pRead <- readCB <$> makeBehavior prevB
        -- always force stuff before calling makeStableName
        !p0 <- liftIO $ pRead
        cache <- liftIO $ do
            stn <- makeStableName p0
            newIORef (stn,f p0)
        let cbeh = ReadCB cRead
            cRead = do
                (stn,c) <- readIORef cache
                !p   <- pRead
                stn' <- makeStableName p
                if stn == stn'
                    then return c
                    else let c' = (f p)
                        in writeIORef cache (stn',c') >> return c'
        addBehavior $ EBehavior lbl cbeh
        return cbeh
makeBehavior (BApp lbl fB prevB) = lookupBehavior lbl >>= \case
    Just (EBehavior lbl' cbeh)
        | lbl == lbl' -> return $ unsafeCoerce cbeh
        | otherwise -> error "buildChains: labels don't match for BApp"
    Nothing -> do
        mTrace $ "BApp " ++ show lbl
        pRead <- readCB <$> makeBehavior prevB
        fRead <- readCB <$> makeBehavior fB
        -- always force stuff before calling makeStableName
        !p0 <- liftIO $ pRead
        !f0 <- liftIO $ fRead
        cache <- liftIO $ do
            stn1 <- makeStableName f0
            stn2 <- makeStableName p0
            newIORef (stn1,stn2,f0 p0)
        let cbeh = ReadCB cRead
            cRead = do
                (stn1,stn2,c) <- readIORef cache
                !p   <- pRead
                !f   <- fRead
                stn1' <- makeStableName f
                stn2' <- makeStableName p
                if stn1 == stn1' && stn2 == stn2'
                    then return c
                    else let c' = (f p)
                        in writeIORef cache (stn1',stn2',c') >> return c'
        addBehavior $ EBehavior lbl cbeh
        return cbeh
makeBehavior (BSwch lbl b prevE) = lookupBehavior lbl >>= \case
    Just (EBehavior lbl' beh)
        | lbl == lbl' -> return (unsafeCoerce beh)
        | otherwise -> error $ "buildChains: labels don't match for BSwch!"
    Nothing -> do
        mTrace $ "BSwch " ++ show lbl
        b0  <- makeBehavior b
        cbs <- liftIO $ makeCBSwitch <$> newIORef b0
        let cbeh = SwchCB cbs
        modify $ addHead (EChain $ CDynB lbl cbs)
        addBehavior $ EBehavior lbl cbeh
        cbeh <$ addChain lbl prevE

-----------------------------------------------------
-- dynamic switching stuff

dynNode :: Label -> ChainM w DynNodeX
dynNode target = error "TODO"

-----------------------------------------------------

-- Takes two inputs, the final sink and a value.  Performs all real terminal
-- actions and returns an action to be performed afterwards (updating
-- behaviors)
type CompiledChain r a = (r -> IO ()) -> a -> IO [UpdateStep]
type UpdateStep = Either (ChainM DynW ()) (IO ())

compileChain :: Chain r a -> CompiledChain r a
compileChain (CEvent _ next) = compileNode next
compileChain (CMap _ f next) =
    let !next' = compileNode next
    in \sink -> next' sink . f

compileChain (COut _) = (([] <$) .)
compileChain (CAcc _ (PushCB _reader writer)) =
    const $ return . pure . Right . writer

compileChain (CAcc _ _) =
    error "Impulse: attempt to accumulate to non-accumulating behavior!"
compileChain (CApply _ cb next) =
    let !next'  = compileNode next
        !reader = readCB cb
    in \sink a -> do
        f <- reader
        next' sink $! f a

-- updating a dynamic behavior
compileChain (CDynB _ (CBSwitch _ w)) =
    \_sink newB -> do
        let act = makeBehavior newB >>= liftIO . w
        return [Left act]

compileNode :: ChainNode (Chain r a) -> CompiledChain r a
compileNode ChainNode{..} =
    let nexts = map compileChain cnChildren
    in foldl' (flip seq) () nexts `seq`
        \sink a -> concat <$> mapM (\f -> f sink a) nexts
