-- Copyright (c) 2026 xoCore Technologies, Benjamin Summers
-- SPDX-License-Identifier: MIT
-- See LICENSE for full terms.

{-# LANGUAGE LambdaCase, ViewPatterns, BlockArguments #-}
{-# LANGUAGE OverloadedStrings, DeriveGeneric, DeriveAnyClass #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE DeriveFunctor, DeriveFoldable, DeriveTraversable #-}

module Types where

import Numeric.Natural
import Control.DeepSeq
import GHC.Generics
import qualified Data.Vector as V
import Data.Vector (Vector)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.Bits (shiftR, (.&.))

data Val
    = P ByteString [Val] !Val   -- hash, sub-pins (shallow), inner value
    | L !Natural Val Val
    | A !Val !(Vector Val)
    | N !Natural
  deriving (Generic)

instance NFData Val where
    rnf (P _ _ v) = rnf v
    rnf (L a m b) = rnf m `seq` rnf b
    rnf (A f xs)  = rnf f `seq` rnf xs
    rnf N{}       = ()

instance Eq Val where
    (==) (P h1 _ _) (P h2 _ _) = h1==h2
    (==) (L a m b)  (L o n p)  = a==o && m==n && b==p
    (==) (A f xs)   (A g ys)   = f==g && xs==ys
    (==) (N n)      (N m)      = n==m
    (==) _          _          = False

nat :: Val -> Natural
nat x = case x of N n -> n; _ -> 0

unapp :: Val -> [Val]
unapp (A f xs) = f : V.toList xs
unapp x        = [x]
