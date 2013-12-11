{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TemplateHaskell #-}

{-# OPTIONS_GHC -Wall #-}
module Reactive.Impulse.Core

where

import Control.Applicative
import Control.Monad.State.Lazy

import Control.Lens

import Data.Semigroup
import Data.IORef
import Control.Concurrent.STM
import qualified Data.Monoid as Monoid

import System.IO.Unsafe (unsafePerformIO)

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
    EUnion :: Label -> Event a -> Event a -> Event a
    EApply :: Label -> Event b -> Behavior (b -> a) -> Event a
    ESwch  :: Label -> Behavior (Event a) -> Event a
    EDyn   :: Label -> Event (SGen a) -> Event a

instance Labelled (Event a) where
    label f (EIn lbl)        = fmap (\l' -> (EIn l')       ) (f lbl)
    label f (EOut lbl a)     = fmap (\l' -> (EOut l' a)    ) (f lbl)
    label f (ENull lbl a)    = fmap (\l' -> (ENull l' a)   ) (f lbl)
    label f (EMap lbl a b)   = fmap (\l' -> (EMap l' a b)  ) (f lbl)
    label f (EUnion lbl a b) = fmap (\l' -> (EUnion l' a b)) (f lbl)
    label f (EApply lbl a b) = fmap (\l' -> (EApply l' a b)) (f lbl)
    label f (ESwch lbl a)    = fmap (\l' -> (ESwch l' a)   ) (f lbl)
    label f (EDyn lbl e)     = fmap (\l' -> (EDyn l' e)    ) (f lbl)

instance Functor Event where
    fmap f e = EMap (unsafePerformIO getLabel) f e

instance Monoid.Monoid (Event a) where
    mempty  = EIn (unsafePerformIO getLabel)
    mappend = EUnion (unsafePerformIO getLabel)

data Behavior a where
    BAcc   :: Label -> a -> Event (a->a) -> Behavior a
    BMap   :: Label -> (b -> a) -> Behavior b -> Behavior a
    BPure  :: Label -> a -> Behavior a
    BApp   :: Label -> Behavior (b -> a) -> Behavior b -> Behavior a
    BSwch  :: Label -> Behavior a -> Event (Behavior a) -> Behavior a

instance Functor Behavior where
    fmap f b = BMap (unsafePerformIO getLabel) f b

instance Applicative Behavior where
    pure a  = BPure (unsafePerformIO getLabel) a
    f <*> a = BApp (unsafePerformIO getLabel) f a

-----------------------------------------------------------

type SGen a = StateT SGState IO a

data SGInput where
    SGInput :: TVar (a -> IO ()) -> Event a -> SGInput
instance Show SGInput where
    show (SGInput _ e) = "SGInput (" ++ show (e^.label) ++ ")"

data SGState = SGState
    { _inputs  :: [SGInput]
    , _outputs :: [Event (IO ())]
    }

$(makeLenses ''SGState)

instance Semigroup SGState where
    l <> r = l & inputs <>~ r^.inputs & outputs <>~ r^.outputs

instance Monoid SGState where
    mempty = SGState [] []
    mappend = (<>)

singleIn :: SGInput -> SGState
singleIn i = SGState [i] []

singleOut :: Event (IO ()) -> SGState
singleOut o = SGState [] [o]

reactimate :: Event (IO ()) -> SGen ()
reactimate e = do
    lbl <- liftIO $ getLabel
    modify (<> singleOut (EOut lbl e))

addInput :: SGInput -> SGen ()
addInput sgi = modify (<> singleIn sgi)

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

