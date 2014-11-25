{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE RankNTypes #-}

{-# OPTIONS_GHC -Wall -fno-warn-unused-imports #-}
module Reactive.Impulse.Core

where

import Control.Applicative
import Control.Monad.State.Lazy

import Control.Lens

import Data.Semigroup
import Data.IORef
import Data.IntMap (IntMap)
import qualified Data.IntMap as IM
import qualified Data.IntSet as IntSet
import Control.Concurrent.STM
import qualified Data.Monoid as Monoid

import System.IO.Unsafe (unsafePerformIO)

import Debug.Trace

-----------------------------------------------------------
-- evil label stuff

type Label  = Int

{-# NOINLINE labelRef #-}
labelRef :: IORef Label
labelRef = unsafePerformIO $ newIORef 0

getLabel :: IO Label
getLabel = do
    !x <- atomicModifyIORef' labelRef $ \l -> let n = succ l in (n,n)
    return x

class Labelled a where
    label :: Lens' a Label

data Event a where
    EIn    :: Label -> Event a
    EOut   :: Label -> Event (IO ()) -> Event (IO ())
    ENull  :: Label -> Event a -> Event a
    EMap   :: Label -> (b -> a) -> Event b -> Event a
    EFilt  :: Label -> (b -> Maybe a) -> Event b -> Event a
    EUnion :: Label -> Event a -> Event a -> Event a
    EApply :: Label -> Event b -> Behavior (b -> a) -> Event a
    ESwch  :: Label -> Behavior (Event a) -> Event a
    EJoin  :: Label -> Event (Event a) -> Event a
    EDyn   :: Label -> Event (SGen a) -> Event a

instance Labelled (Event a) where
    label f (EIn lbl)        = fmap (\l' -> (EIn l')       ) (f lbl)
    label f (EOut lbl a)     = fmap (\l' -> (EOut l' a)    ) (f lbl)
    label f (ENull lbl a)    = fmap (\l' -> (ENull l' a)   ) (f lbl)
    label f (EMap lbl a b)   = fmap (\l' -> (EMap l' a b)  ) (f lbl)
    label f (EFilt lbl a b)  = fmap (\l' -> (EFilt l' a b) ) (f lbl)
    label f (EUnion lbl a b) = fmap (\l' -> (EUnion l' a b)) (f lbl)
    label f (EApply lbl a b) = fmap (\l' -> (EApply l' a b)) (f lbl)
    label f (ESwch lbl a)    = fmap (\l' -> (ESwch l' a)   ) (f lbl)
    label f (EJoin lbl e)    = fmap (\l' -> (EJoin l' e)   ) (f lbl)
    label f (EDyn lbl e)     = fmap (\l' -> (EDyn l' e)    ) (f lbl)

instance Functor Event where
    fmap f e = unsafePerformIO $ getLabel >>= \lbl -> return $ EMap lbl f e

instance Monoid.Monoid (Event a) where
    mempty  = EIn (-1)
    mappend l r = unsafePerformIO $ getLabel >>= \lbl -> return $ EUnion lbl l r
    mconcat = binConcat

data Behavior a where
    BAcc   :: Label -> a -> Event (a->a) -> Behavior a
    BMap   :: Label -> (b -> a) -> Behavior b -> Behavior a
    BPure  :: Label -> a -> Behavior a
    BApp   :: Label -> Behavior (b -> a) -> Behavior b -> Behavior a
    BSwch  :: Label -> Behavior a -> Event (Behavior a) -> Behavior a

instance Functor Behavior where
    fmap f b = unsafePerformIO $ getLabel >>= \lbl -> return $ BMap lbl f b

instance Applicative Behavior where
    pure a  = unsafePerformIO $ getLabel >>= \lbl -> return $ BPure lbl a
    f <*> a = unsafePerformIO $ getLabel >>= \lbl -> return $ BApp lbl f a

-----------------------------------------------------------

binConcat :: Monoid a => [a] -> a
binConcat []  = mempty
binConcat xs0 = go xs0  -- non-Empty
  where
    go xs = case pairUp xs of
      [x] -> x
      xs' -> go xs'

pairUp :: Monoid a => [a] -> [a]
pairUp = go
  where
    go (x:y:zs) = let !z' = (x `mappend` y)
                  in z' : go zs
    go xs = xs

-----------------------------------------------------------

type SGen a = StateT SGState IO a

data SGInput where
    SGInput :: TVar (a -> IO ()) -> Event a -> SGInput

instance Show SGInput where
    show (SGInput _ e) = "SGInput (" ++ show (e^.label) ++ ")"

data SGState = SGState
    { _inputs  :: !(IM.IntMap SGInput)
    , _outputs :: ![Event (IO ())]
    , _sgDirtyLog :: DirtyLog
    }

type ChainSet = IntSet.IntSet

newtype DirtyChains = DirtyChains ChainSet deriving (Eq, Show, Monoid, Semigroup)

data FireOnce where
    FireOnce :: Label -> a -> FireOnce

instance Labelled FireOnce where
    label f (FireOnce lbl a) = fmap (\l' -> FireOnce l' a  ) (f lbl)

instance Labelled SGInput where
    label f (SGInput a evt) = fmap (\evt' -> SGInput a evt' ) (label f evt)

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

newtype ChainEdgeMap = ChainEdgeMap (IntMap ChainSet) deriving (Show)

instance Semigroup ChainEdgeMap where
    ChainEdgeMap l <> ChainEdgeMap r = ChainEdgeMap (IM.unionWith IntSet.union l r)

instance Monoid ChainEdgeMap where
    mempty  = ChainEdgeMap mempty
    mappend = (<>)

$(makeLenses ''SGState)

instance Semigroup SGState where
    SGState l1 l2 l3 <> SGState r1 r2 r3 =
        SGState (l1<>r1) (l2<>r2) (l3<>r3)

instance Monoid SGState where
    mempty = SGState mempty [] mempty
    mappend = (<>)

reactimate :: Event (IO ()) -> SGen ()
reactimate e = do
    lbl <- liftIO $ getLabel
    outputs %= (EOut lbl e:)

addInput :: SGInput -> SGen ()
addInput sgi = do
    inputs %= (IM.insert (sgi^.label) sgi)
    !_ <- get
    return ()

newAddHandler :: SGen ((a -> IO ()), Event a)
newAddHandler = do
    (inp,pusher,evt) <- liftIO $ do
        ref <- newTVarIO (const $ return ())
        lbl <- getLabel
        let evt = EIn lbl
            inp = SGInput ref evt
            pusher a = readTVarIO ref >>= ($ a)
        return (inp, pusher, evt)
    addInput inp
    return (pusher,evt)

-----------------------------------------------------------

mTrace :: Monad m => String -> m ()
mTrace = const $ return ()
-- mTrace t = trace t $ return ()

