{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE TemplateHaskell #-}

{-# OPTIONS_GHC -Wall #-}
module Reactive.Impulse.Internal.Types
where

import Reactive.Impulse.Core
import Reactive.Impulse.Internal.RWST hiding ((<>))

import Control.Applicative
import Control.Concurrent.STM
import Control.Concurrent.MVar
import Control.Lens
import Control.Monad.Identity

import Data.IntMap (IntMap)
import qualified Data.IntMap as IM
import qualified Data.IntSet as IntSet
import qualified Data.Monoid as Monoid
import Data.Tree
import Data.Semigroup

import Unsafe.Coerce
import System.Mem.Weak

type ChainSet = IntSet.IntSet

newtype ChainEdgeMap = ChainEdgeMap (IntMap ChainSet) deriving (Show)

instance Semigroup ChainEdgeMap where
    ChainEdgeMap l <> ChainEdgeMap r = ChainEdgeMap (IM.unionWith IntSet.union l r)

instance Monoid ChainEdgeMap where
    mempty  = ChainEdgeMap mempty
    mappend = (<>)

simpleEdgeMap :: Label -> ChainSet -> ChainEdgeMap
simpleEdgeMap fromLbl toSet = ChainEdgeMap $ IM.singleton fromLbl toSet

newtype MkWeak = MkWeak {unMkWeak :: forall a. a -> Maybe (IO ()) -> IO (Weak a)}

data PrevSwchRef = PrevSwchRef
    { _psrEdgeMap :: ChainEdgeMap
    , _psrMkWeaks :: ChainM ()
    }

emptyPrevSwchRef :: PrevSwchRef
emptyPrevSwchRef = PrevSwchRef mempty (return ())

data ChainNode t = ChainNode
    { _cnChildren  :: [ t ]    -- direct children of this node
    , _cnPushSet   :: ChainSet -- all transitive children of this node
    } deriving Functor

data Chain r a where
    CEvent :: Label -> ChainNode (Chain r a) -> Chain r a
    CMap   :: Label -> (a -> b) -> ChainNode (Chain r b) -> Chain r a
    COut   :: Label -> Chain (IO ()) (IO ())
    CAcc   :: Label -> CBehavior a -> Chain r (a->a)
    CApply :: Label -> CBehavior (a -> b) -> ChainNode (Chain r b) -> Chain r a
    CSwch  :: Label -> CBSwitch (CBehavior a) -> Chain r (Behavior a)
    CSwchE :: Label -> TVar PrevSwchRef -> CBehavior (Event a)
              -> ChainNode (Chain r a) -> Chain r ()
    CDyn   :: (a ~ SGen b) => Label -> ChainNode (Chain r b) -> Chain r a

-- A CBehavior is the representation of a Behavior within a Chain.
data CBehavior a =
    ReadCB (STM a)
  | PushCB (TVar a) -- (IO a) ((a -> a) -> IO ())
  | SwchCB { _swchcb :: {-# UNPACK #-} !(CBSwitch (CBehavior a)) }

-- only used for dynamic network switching
data CBSwitch a = CBSwitch (TVar a) -- (IO a) (a -> IO ())

instance Labelled (Chain r a) where
    label f (CEvent lbl a)   = fmap (\l' -> CEvent l' a  ) (f lbl)
    label f (CMap lbl a b)   = fmap (\l' -> CMap l' a b  ) (f lbl)
    label f (COut lbl)       = fmap (\l' -> COut l'      ) (f lbl)
    label f (CAcc lbl a)     = fmap (\l' -> CAcc l' a    ) (f lbl)
    label f (CApply lbl a b) = fmap (\l' -> CApply l' a b) (f lbl)
    label f (CDyn lbl a)     = fmap (\l' -> CDyn l' a    ) (f lbl)
    label f (CSwch lbl a)    = fmap (\l' -> CSwch l' a   ) (f lbl)
    label f (CSwchE lbl tv a b) = fmap (\l' -> CSwchE l' tv a b) (f lbl)

type PermHead = Bool

-- wrap chains to put them in a map
data EChain where
    EChain :: PermHead -> Chain (IO ()) a -> EChain

permHead :: Lens' EChain PermHead
permHead = lens (\(EChain p _) -> p) (\(EChain _ c) p -> EChain p c)

instance Labelled EChain where
    label = from echain . label
    -- alt def. would work if the unsafeCoerce ever causes issues,
    -- but I think it's ok here...
    -- label = lens (\(EChain c) -> c^.label) (\(EChain c) l' -> EChain $ set label l' c)

data EBehavior where
    EBehavior :: Label -> CBehavior a -> EBehavior

instance Labelled EBehavior where
    label f (EBehavior lbl b) = fmap (\l' -> EBehavior l' b) (f lbl)

-- haha this is super-sketchy.
echain :: Iso' (Chain (IO ()) a) EChain
echain = iso (EChain False) (\(EChain _ c) -> unsafeCoerce c)

-----------------------------------------------------------

-- A map from heads into a boundary region.  Used when constructing sub-graphs
newtype BoundaryMap = BoundaryMap (IntMap ChainSet)

-- a DynGraph is a collection of chains that can be compiled
-- and/or executed.  It is basically a map of chain heads.

data DynGraph f w = DynGraph
  { _dgHeads     :: f (IntMap (w EChain))
  , _dgBehaviors :: f (IntMap (w EBehavior))
  , _dgBoundMap  :: BoundaryMap
  , _dgMkWeaks   :: IntMap MkWeak
  }

-- a pure, immutable structure that is purely modifiable.  Useful for creating
-- the initial graph and sub-graphs.
type BuildingDynGraph = DynGraph Identity Identity

startBuildingGraph :: Applicative t => DynGraph t a
startBuildingGraph = DynGraph (pure IM.empty) (pure IM.empty) mempty mempty

-- a running graph, using weak references and mutable refs.
type RunningDynGraph  = DynGraph TVar Weak
  {- for a RunningDynGraph, dgBehaviors need to be weak refs keyed off the
   - underlying tvar
   - dgHeads should be alive so long as the underlying Event is live.
   -}

-- A running graph, frozen so that multiple functions can modify it.
data FrozenDynGraph = FrozenDynGraph
    { _frozenSource   :: DynGraph Identity Weak
    , _frozenMutGraph :: DynGraph Identity Identity
    }

emptyFrozenGraph :: FrozenDynGraph
emptyFrozenGraph = FrozenDynGraph startBuildingGraph startBuildingGraph

newtype DirtyChains = DirtyChains ChainSet deriving (Eq, Show, Monoid, Semigroup)

-- a Network is a set of input nodes and a RunningDynGraph.  These structures
-- are designed to use Weak references so they don't retain the internal graph
-- structure or input nodes, and to be adjustable at runtime.
data Network = Network
    { _nInputs   :: NetHeadMap
    , _nDynGraph :: RunningDynGraph
    , _nPaused   :: TVar (Maybe NetworkPausing)
    , _nActions  :: TVar (IO ())
    , _nLock     :: MVar ()
    }

data NetworkPausing = NetworkPausing
    { _npPausedInputs :: IntMap PInput }

data EInput where
    EInput :: Weak (TVar (a -> IO ())) -> EInput

data PInput where
    PInput :: (TVar (a -> IO ())) -> (a -> IO ()) -> PInput

type NetHeadMap = TVar (IntMap EInput)

newtype BoundarySet = BoundarySet ChainSet deriving (Eq, Ord, Monoid, Semigroup)

data FireOnce where
    FireOnce :: Label -> a -> FireOnce

instance Labelled FireOnce where
    label f (FireOnce lbl a) = fmap (\l' -> FireOnce l' a  ) (f lbl)

data DirtyLog = DirtyLog
    { _dlChains :: !DirtyChains
    , _dlEvents :: Endo [FireOnce]
    , _dlRemSet :: !ChainEdgeMap
    , _dlAddInp :: Endo [SGInput]
    }

instance Semigroup DirtyLog where
    DirtyLog l1 l2 l3 l4 <> DirtyLog r1 r2 r3 r4 =
     DirtyLog (l1<>r1) (l2<>r2) (l3<>r3) (l4<>r4)

instance Monoid DirtyLog where
    mempty = DirtyLog mempty mempty mempty mempty
    mappend = (<>)

-- The ModGraphM monad keeps track of a BuildingDynGraph during construction,
-- with access to a FrozenDynGraph.
type ModGraphM = RWST FrozenDynGraph DirtyLog BuildingDynGraph STM

-- The ChainM monad keeps track of a BuildingDynGraph during construction.
-- Only need the W param for CSwchE chains, to mark chains where the output
-- was removed, and to fire the initial event switch.
type ChainM = RWST BoundarySet DirtyLog BuildingDynGraph STM

-- Takes two inputs, the final sink and a value.  Performs all real terminal
-- actions and returns an action to be performed afterwards.
type CompiledChain r a = (r -> IO ()) -> a -> IO [UpdateStep]

-- There are 3 phases to updates:
--  1. Read from behaviors
--  2. Run reactimated code
--  3. Write to behaviors.
--
--  The first phase is handled by the IO result of CompiledChain.
--  The second/third phases are inverted: we construct an action that writes to
--  behaviors and returns the reactimation runners.  We do it this way as an
--  artifact of using STM (although that's going to go away soon).
data UpdateStep =
    Norm (STM (IO ()))
  | Mod  (ChainM ())
  | DynMod (ChainM ()) (IO [UpdateStep])
  -- for DynMod, we first need to run the ChainM action to update the graph.
  -- then we continue with running the update steps.  In this case, we need to
  -- grab the extra IO layer to do the initial behavior readings after the
  -- graph has been updated (since updating the graph may cause events to fire
  -- and behaviors to update).

useUpdateStep :: (STM (IO ()) -> b) -> (ChainM () -> b) -> (ChainM () -> IO [UpdateStep] -> b) -> UpdateStep -> b
useUpdateStep f g h u = case u of
    Norm x -> f x
    Mod  x -> g x
    DynMod x y -> h x y

emptyCompiledChain :: CompiledChain r a
emptyCompiledChain _ _ = return []

$(makeIso ''ChainEdgeMap)
$(makeIso ''DirtyChains)
$(makePrisms ''CBehavior)
$(makePrisms ''UpdateStep)
$(makeLenses ''PrevSwchRef)
$(makeLenses ''Network)
$(makeLenses ''NetworkPausing)
$(makeLenses ''FrozenDynGraph)
$(makeLenses ''DynGraph)

$(makeLenses ''DirtyLog)

markDirty :: Label -> ModGraphM ()
markDirty l = scribe dlChains $ DirtyChains $ IntSet.singleton l

markDirties :: ChainSet -> ModGraphM ()
markDirties = scribe dlChains . DirtyChains

$(makeLenses ''ChainNode)

-- update the node children, and also update the pushSet to match.
alterChildren :: ChainNode t -> ([t] -> [Chain r a]) -> ChainNode (Chain r a)
alterChildren cn f =
    let newChildren = cn^.cnChildren.to f
    in cn & cnChildren .~ newChildren
          & cnPushSet .~ (newChildren^.folded.cPushSet')

instance Semigroup (ChainNode t) where
    l <> r = l & cnChildren <>~ r^.cnChildren
               & cnPushSet %~ ( flip IntSet.union $ r^.cnPushSet)

instance Monoid.Monoid (ChainNode t) where
    mempty = ChainNode [] IntSet.empty
    mappend = (<>)

cPushSet' :: IndexPreservingGetter (Chain r a) ChainSet
cPushSet' = to f
  where
    f (CEvent l n)     = IntSet.singleton l <> n^.cnPushSet
    f (CMap l _ n)     = IntSet.singleton l <> n^.cnPushSet
    f (CApply l _ n)   = IntSet.singleton l <> n^.cnPushSet
    f (CSwchE l _ _ n) = IntSet.singleton l <> n^.cnPushSet
    f c                = IntSet.singleton (c^.label)

cPushSet :: IndexPreservingGetter (Chain r a) (Maybe ChainSet)
cPushSet = to f
  where
    f (CEvent _ n)     = Just $ n^.cnPushSet
    f (CMap _ _ n)     = Just $ n^.cnPushSet
    f (CApply _ _ n)   = Just $ n^.cnPushSet
    f (CSwchE _ _ _ n) = Just $ n^.cnPushSet
    f _                = Nothing

$(makeIso ''BoundaryMap)

instance Semigroup BoundaryMap where
    l <> r = under boundaryMap (IM.unionWith (<>) (r^.from boundaryMap)) l

instance Monoid BoundaryMap where
    mappend = (<>)
    mempty  = BoundaryMap mempty

$(makeIso ''BoundarySet)

cBoundarySet :: IndexPreservingGetter EChain BoundarySet
cBoundarySet = to f.boundarySet
  where
    f (EChain _ (CEvent l n))   = IntSet.insert l $ n^.cnPushSet
    f (EChain _ (CMap l _ n))   = IntSet.insert l $ n^.cnPushSet
    f (EChain _ (CApply l _ n)) = IntSet.insert l $ n^.cnPushSet
    f e              = IntSet.singleton (e^.label)

chainLabelTree :: Chain r a -> Tree String
chainLabelTree c =
    Node {rootLabel = thisLbl ++ (c^.label.to show), subForest = mkForest }
  where
    (thisLbl,mkForest) = case c of
        (CEvent _ n)     -> ("CEvent ", map chainLabelTree $ n^.cnChildren)
        (CMap _ _ n)     -> ("CMap "  , map chainLabelTree $ n^.cnChildren)
        (CApply _ _ n)   -> ("CApply ", map chainLabelTree $ n^.cnChildren)
        (CSwchE _ _ _ n) -> ("CSwchE ", map chainLabelTree $ n^.cnChildren)
        CDyn _ n         -> ("CDyn ",   map chainLabelTree $ n^.cnChildren)
        COut{}  -> ("COut " , [])
        CSwch{} -> ("CSwch ", [])
        CAcc{}  -> ("CAcc " , [])

showChainTree :: Chain r a -> String
showChainTree = drawTree . chainLabelTree
