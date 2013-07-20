{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE GADTs #-}
module Reactive.Test where

import Reactive.Impulse
import Reactive.Impulse.Core
import Control.Applicative
import Data.Monoid

import Control.Monad.IO.Class

net1 :: SGen (Int -> IO ())
net1 = do
    (push,e1) <- newAddHandler
    reactimate $ print <$> e1
    return push

net2 :: SGen (Int -> IO (), String -> IO ())
net2 = do
    (push1,e1) <- newAddHandler
    reactimate $ print <$> e1
    (push2,e2) <- newAddHandler
    reactimate $ putStrLn <$> e2
    return (push1,push2)

net3 :: SGen (Int -> IO ())
net3 = do
    (push1,e1) <- newAddHandler
    reactimate $ putStrLn . ("r1 " ++) . show <$> e1
    let sumB = accumB 0 ((+) <$> e1)
        accB :: Behavior (a -> Int)
        accB = const <$> sumB
        sumE :: Event Int
        sumE = applyB e1 accB
        s2E  = (putStrLn . ("r2 " ++) . show) <$> sumE
    reactimate s2E
    liftIO $ print s2E
    return push1

net4 :: SGen (Int -> IO (), Bool -> IO ())
net4 = do
    (push1,e1) <- newAddHandler
    (push2,boolE) <- newAddHandler
    reactimate $ putStrLn . ("r1 " ++) . show <$> e1
    reactimate $ putStrLn . ("r bool " ++) . show <$> boolE
    let opB = stepper (+) $ (\flag -> if flag then (+) else subtract) <$> boolE
        fnE  = applyB e1 opB
        sumB = accumB 0 fnE
        sumE :: Event Int
        sumE = sample e1 sumB
        s2E  = (putStrLn . ("r2 " ++) . show) <$> sumE
    reactimate s2E
    liftIO $ print s2E
    return (push1,push2)

net4b :: SGen (Int -> IO (), Bool -> IO ())
net4b = do
    (push1,e1) <- newAddHandler
    (push2,boolE) <- newAddHandler
    reactimate $ putStrLn . ("r1 " ++) . show <$> e1
    reactimate $ putStrLn . ("r bool " ++) . show <$> boolE
    let opB = accumB (+) $ ((\flag _ -> if flag then (+) else subtract) <$> boolE)
        fnE  = applyB e1 opB
        sumB = accumB 0 fnE
        sumE :: Event Int
        sumE = sample e1 sumB
        s2E  = (putStrLn . ("r2 " ++) . show) <$> sumE
    reactimate s2E
    liftIO $ print s2E
    return (push1,push2)


instance Show (Event a) where
    show (EIn l) = "EIn " ++ show l
    show (EOut l p) = "EOut " ++ show l ++ " ( " ++ show p ++ ")"
    show (ENull l p) = "ENull " ++ show l ++ " ( " ++ show p ++ ")"
    show (EMap l _ p) = "EMap " ++ show l ++ " ( " ++ show p ++ ")"
    show (EUnion l p q) = "EUnion " ++ show l ++ " ( " ++ show p ++ ") ( " ++ show q ++ ")"
    show (EApply l e b) = "EApply " ++ show l ++ " ( " ++ show e ++ ") ( " ++ show b ++ ")"

instance Show (Behavior a) where
    show (BAcc l _ p) = "BAcc " ++ show l ++ " ( " ++ show p ++ ")"
    show (BMap l _ p) = "BMap " ++ show l ++ " ( " ++ show p ++ ")"
    show (BPure l _)  = "BPure " ++ show l
    show (BApp l f p) = "BApp " ++ show l ++ " ( " ++ show f ++ ") ( " ++ show p ++ ")"
    show (BSwch l b p) = "BSwch " ++ show l ++ " ( " ++ show b ++ ") ( " ++ show p ++ ")"
