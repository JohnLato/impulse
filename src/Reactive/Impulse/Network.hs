{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE RecursiveDo #-}

{-# OPTIONS_GHC -Wall #-}
module Reactive.Impulse.Network (
  Network (..)
, compileNetwork
, startNetwork
, stopNetwork
) where

import Reactive.Impulse.Core
import Reactive.Impulse.Chain

import Control.Applicative
import Control.Monad.State.Lazy

import Data.IORef
import qualified Data.IntMap as IM
import Data.Monoid

import Unsafe.Coerce

-----------------------------------------------------------
-- Network, starting/stopping.

-- a Network is a set of inputs and chains.  It doesn't ref the whole 
-- event graph so that Events can be GC'd if they're no longer used.
-- TODO: reconfigure the chain/behavior mapping and make it use weak refs
-- so those elements can be GC'd also.
data Network = Network
    { nInputs :: [SGInput]
    , nChains :: (Chains,Behaviors)
    }

compileNetwork :: SGen a -> IO (a,Network)
compileNetwork net = do
    (a,SGState {..}) <- runStateT net (SGState [] [])
    let edges = calcAllOutEdges outputs
    nChains <- snd <$> execStateT (buildChains outputs) (edges,mempty)
    return $ (a, Network { nInputs = inputs, nChains })

-- TODO: cache the built actions somewhere
startNetwork :: Network -> IO ()
startNetwork Network {..} = do
    forM_ (reverse nInputs) $ \(SGInput ref (EIn lbl)) -> do
        mTrace $ "compiling input " ++ show lbl
        case IM.lookup lbl (fst nChains) of
            Nothing -> error $ "runNetwork: no node for input: " ++ show lbl
            Just ChainNode {..} -> do
                eTerms <- forM (reverse cnTerminals) $ \(EChain lbl' _ chain) -> do
                    mTrace $ "terminal e " ++ show lbl'
                    when (lbl' /= lbl) $ error "runNetwork: label mismatch"
                    actK <- compileChain chain
                    return $ (unsafeCoerce actK) id
                -- these aren't actually directly behaviors, they're chains
                -- that ultimately push to behaviors.
                -- keeping them separate because they'll need to be
                -- for the cache.
                eBehaviors <- forM (reverse cnBehaviors) $ \(EChain lbl' _ chain) -> do
                    mTrace $ "terminal b " ++ show lbl'
                    when (lbl' /= lbl) $ error "runNetwork: label mismatch b"
                    actK <- compileChain chain
                    return $ (unsafeCoerce actK) id
                let actions = sequence_ . sequence (eTerms ++ eBehaviors)
                writeIORef ref actions

-- terminate a network (TODO: make this pause)
stopNetwork :: Network -> IO ()
stopNetwork Network {..} = forM_ nInputs $
    \(SGInput ref _) -> writeIORef ref (const $ return ())

