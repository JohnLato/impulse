{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_GHC -Wall #-}
module Reactive.Impulse.Syntax2 (
  Signal
, signalNetwork
) where

import Reactive.Impulse.Syntax
import Reactive.Impulse.Network

import Control.Applicative
import Control.Monad
import Control.Monad.IO.Class
import Data.Either
import Data.Monoid

data Signal a where
    SPure :: a -> Signal a
    SUnion :: [Signal a] -> Signal a
    SFmap  :: (x -> a) -> Signal x -> Signal a
    SAmap  :: Signal (x->a) -> Signal x -> Signal a
    SFold  :: (a->x->a) -> a -> Signal x -> Signal a
    SJoin  :: Signal (Signal a) -> Signal a
    SIn    :: ((a -> IO ()) -> IO ()) -> Signal a
    SOut   :: Signal (IO ())    -> Signal a

instance Monoid (Signal a) where
    mempty = SUnion []
    mappend l r = SUnion [l,r]
    mconcat xs  = SUnion xs

instance Functor Signal where
    fmap = SFmap

instance Applicative Signal where
    pure = SPure
    (<*>) = SAmap

instance Monad Signal where
    return = SPure
    m >>= f = SJoin $ f <$> m

signalNetwork :: Signal (IO ()) -> IO Network
signalNetwork s = do
    ((),net) <- compileNetwork finalSGen
    startNetwork net
    return net
  where
    finalSGen = compileSignal s >>= \case
        Left e -> reactimate e
        Right x -> onCreation x >>= reactimate

compileSignal :: forall a. Signal a -> SGen (Either (Event a) a)
compileSignal sig = case sig of
    SPure a  -> return $ Right a
    SUnion xs -> Left . mconcat . lefts <$> mapM compileSignal xs
    SFmap f s -> mapE f <$> compileSignal s
    SAmap l r -> do
        lEB <- compileSignal l
        rEB <- compileSignal r
        case (lEB,rEB) of
            (Left l', Left r') ->
                let cacheL = stepper (const Nothing) (fmap Just <$> l')
                    cacheR = stepper Nothing (Just <$> r')
                in return $ Left $ justE
                      $  applyE (fmap <$> l') cacheR
                      <> applyB r' cacheL
            (Left l', Right r') ->
                return $ Left $ ($ r') <$> l'
            (Right l', Left r') ->
                return $ Left $ l' <$> r'
            (Right l', Right r') -> return $ Right $ l' r'
    SFold f s0 s -> do
        compileSignal s >>= \case
            Left  s' ->
                let accB = stepper s0 newE
                    newE = applyB s' (f <$> accB)
                in return $ Left newE
            Right s' -> return . Right $ f s0 s'
    SJoin s -> do
        compileSignal s >>= \case
            Right outer -> compileSignal outer
            Left outerE -> do
              let e1 :: Event (SGen (Event a))
                  e1 = (either return onCreation <=< compileSignal) <$> outerE
              return . Left . joinE $ dynE e1
    SOut s -> do
        compileSignal s >>= \case
            Left s' -> Left mempty <$ reactimate s'
            Right _ -> return $ Left mempty
    SIn k -> do
        (p,e) <- newAddHandler
        liftIO $ k p
        return $ Left e

mapE :: (Functor f) => (a->b) -> Either (f a) a -> Either (f b) b
mapE f = either (Left . fmap f) (Right . f)

justE :: Event (Maybe a) -> Event a
justE = filterE id
