-- Copyright (c) 2026 Benjamin Summers
-- SPDX-License-Identifier: AGPL-3.0-only
-- See LICENSE for full terms.

{-# LANGUAGE LambdaCase, ViewPatterns, BlockArguments #-}
{-# LANGUAGE OverloadedStrings, DeriveGeneric, DeriveAnyClass #-}
{-# LANGUAGE MagicHash #-}

module Plan where

import Data.IORef
import System.IO.Unsafe (unsafePerformIO)
import Control.Monad
import qualified Data.Vector as V
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base58 as Base58
import Data.ByteString (ByteString)
import Data.Vector (Vector, (!))
import Data.String (IsString(..))
import Control.DeepSeq (force, deepseq)
import Debug.Trace
import Data.List (nub)
import Data.Bits (shiftR, shiftL, clearBit, setBit, testBit, bit, (.&.), (.|.))
import GHC.Num.Natural (naturalSizeInBase#)
import GHC.Exts (Int(I#), word2Int#)
import GHC.Word (Word8)
import Control.Exception
import Data.Functor ((<&>))
import System.IO (stdin, stdout, stderr, Handle, hFlush)
import Numeric.Natural (Natural)
import System.Directory (doesFileExist, createDirectoryIfMissing, getModificationTime)
import System.FilePath ((</>))
import Data.Time.Clock.POSIX (getPOSIXTime, utcTimeToPOSIXSeconds)
import qualified Crypto.Hash.SHA256 as SHA256
import qualified Data.ByteString.Char8 as BS8

import Types
import Print

arity (A f xs)      = if af==0 then 0 else af - fromIntegral (length xs)
                        where af = arity f
arity (P _ _ (L a _ _)) = a
arity (L a _ _)     = a
arity (N _)         = 0
arity (P _ _ _)     = 1

match p _ _ _ _ (P _ _ i)     = p % i
match _ l _ _ _ (L a m b) = l % N a % m % b
match _ _ a _ _ (A f xs)  = a % ini % (xs!nid)
                       where nid = V.length xs - 1
                             ini = if nid==0 then f else A f (V.take nid xs)
match _ _ _ z m (N o)     = if o==0 then z else m % N (o-1)

(%) f x = if arity f /= 1 then clz f x else exec f [x]

clz :: Val -> Val -> Val
clz (A f xs) x = A f (V.snoc xs x)
clz f        x = A f (V.singleton x)

exec :: Val -> [Val] -> Val
exec (P _ _ (N o))       e = op o (unapp (e!!0))
exec (A f x)         e = exec f (V.toList x <> e)
exec f@(L a m b)     e = judge a (reverse (f : e)) b
exec f@(P _ _ (L a m b)) e = judge a (reverse (f : e)) b
exec (P _ _ x)           e = error $ show ("running bad pin", x, e)

kal :: Natural -> [Val] -> Val -> Val
kal n e expr = case unapp expr of
    [N b] | b<=n -> e !! fromIntegral (n-b)
    [N 0, f, x]  -> (kal n e f % kal n e x)
    [N 0, x]     -> x
    _            -> expr

judge :: Natural -> [Val] -> Val -> Val
judge args ie body = res
  where (n, e, res::Val) = go args ie body
        go i acc x = case unapp x of
            [N 1, v, k] -> go (i+1) (kal n e v : acc) k
            _           -> (i, acc, kal n e x)

data PlanExn = PLAN_EXN !Val
  deriving (Exception)

instance Show PlanExn where
    show (PLAN_EXN x) = showVal x

bitWidth :: Natural -> Int
bitWidth n = I# (word2Int# (naturalSizeInBase# 2## n))

-- Collect all P nodes reachable in a value, shallow (don't recurse
-- into pins), in left-to-right traversal order.
collectSubPins :: Val -> [Val]
collectSubPins = go
  where
    go p@P{}     = [p]
    go (L _ m b) = go m <> go b
    go (A f xs)  = go f <> concatMap go (V.toList xs)
    go (N _)     = []

-- Smart constructor: pretty-print the value, SHA-256 hash it, collect
-- sub-pins, and wrap in P.
mkPin :: Val -> Val
mkPin v = P h pins v
  where
    h    = SHA256.hash (BS8.pack (canonize pins v))
    pins = nub (collectSubPins v)

maxint :: Natural
maxint = fromIntegral (maxBound :: Int)

instance IsString Natural where
    fromString = strNat

instance IsString Val where
    fromString = N . strNat

toix n = if n > maxint then maxBound else fromIntegral n

dec 0 = 0
dec n = n-1

writeByte :: Natural -> Int -> Word8 -> Natural
writeByte n i b = (n `shiftR` top `shiftL` top)
              .|. (fromIntegral b `shiftL` off)
              .|. (n .&. ((1 `shiftL` off) - 1))
  where off = 8 * i
        top = off + 8

op :: Natural -> [Val] -> Val
op 0 [N 0, !n]                = mkPin n
op 0 [N 1, !a, !m, !b]        = L (nat a + 1) m b
op 0 [N 2, p, l, a, z, m, !o] = match p l a z m o

op 66 ["Pin", i]                  = mkPin i
op 66 ["Law", !a, !m, !b]         = L (nat a + 1) m b
op 66 ["Elim", p, l, a, z, m, !o] = match p l a z m o

op 66 ["Inc", x]    = N $ succ $ nat x
op 66 ["Dec", x]    = N $ dec $ nat x
op 66 ["Add", x, y] = N (nat x + nat y)
op 66 ["Sub", x, y] = N (if ny >= nx then 0 else nx - ny)
    where { nx = nat x; ny = nat y }

op 66 ["Rsh", x, y]         = N (nat x `shiftR` toix (nat y))
op 66 ["Lsh", x, y]         = N (nat x `shiftL` toix (nat y))
op 66 ["Div", x, y]         = N (nat x `div` nat y)
op 66 ["Mul", x, y]         = N (nat x * nat y)
op 66 ["Mod", x, y]         = N (nat x `mod` nat y)

op 66 ["Case2",x,a,fb] =
    case x of N 0->a; _->fb
op 66 ["Case3",x,a,b,fb] =
    case x of N 0->a; N 1->b; _->fb
op 66 ["Case4",x,a,b,c,fb] =
    case x of N 0->a; N 1->b; N 2->c; _->fb
op 66 ["Case5",x,a,b,c,d,fb] =
    case x of N 0->a; N 1->b; N 2->c; N 3->d; _->fb
op 66 ["Case6",x,a,b,c,d,e,fb] =
    case x of N 0->a; N 1->b; N 2->c; N 3->d; N 4->e; _->fb
op 66 ["Case7",x,a,b,c,d,e,f,fb] =
    case x of N 0->a; N 1->b; N 2->c; N 3->d; N 4->e; N 5->f; _->fb
op 66 ["Case8",x,a,b,c,d,e,f,g,fb] =
    case x of N 0->a; N 1->b; N 2->c; N 3->d; N 4->e; N 5->f; N 6 ->g; _->fb
op 66 ["Case9",x,a,b,c,d,e,f,g,h,fb] =
    case x of N 0->a; N 1->b; N 2->c; N 3->d; N 4->e; N 5->f; N 6->g; N 7->h
              _->fb
op 66 ["Case10",x,a,b,c,d,e,f,g,h,i,fb] =
    case x of N 0->a; N 1->b; N 2->c; N 3->d; N 4->e; N 5->f; N 6->g; N 7->h
              N 8->i; _->fb
op 66 ["Case11",x,a,b,c,d,e,f,g,h,i,j,fb] =
    case x of N 0->a; N 1->b; N 2->c; N 3->d; N 4->e; N 5->f; N 6->g; N 7->h
              N 8->i; N 9->j; _->fb
op 66 ["Case12",x,a,b,c,d,e,f,g,h,i,j,k,fb] =
    case x of N 0->a; N 1->b; N 2->c;  N 3->d; N 4->e; N 5->f; N 6->g; N 7->h
              N 8->i; N 9->j; N 10->k; _->fb
op 66 ["Case13",x,a,b,c,d,e,f,g,h,i,j,k,l,fb] =
    case x of N 0->a; N 1->b; N 2->c;  N 3->d;  N 4->e; N 5->f; N 6->g; N 7->h
              N 8->i; N 9->j; N 10->k; N 11->l; _->fb
op 66 ["Case14",x,a,b,c,d,e,f,g,h,i,j,k,l,m,fb] =
    case x of N 0->a; N 1->b; N 2->c;  N 3->d;  N 4->e;  N 5->f; N 6->g; N 7->h
              N 8->i; N 9->j; N 10->k; N 11->l; N 12->m; _->fb
op 66 ["Case15",x,a,b,c,d,e,f,g,h,i,j,k,l,m,n,fb] =
    case x of N 0->a; N 1->b; N 2->c;  N 3->d;  N 4->e;  N 5->f; N 6->g; N 7->h
              N 8->i; N 9->j; N 10->k; N 11->l; N 12->m; N 13->n; _->fb
op 66 ["Case16",x,a,b,c,d,e,f,g,h,i,j,k,l,m,n,o,fb] =
    case x of N 0->a; N 1->b; N 2->c;  N 3->d;  N 4->e;  N 5->f;  N 6->g; N 7->h
              N 8->i; N 9->j; N 10->k; N 11->l; N 12->m; N 13->n; N 14->o; _->fb

op 66 ["Case", ix, cs, f]   = case (cs, ix) of
    (A _ xs, N i) | i < fromIntegral (length xs) -> xs `V.unsafeIndex` toix i
    _                                            -> f

op 66 ["Test", i, n]   = planBit $ testBit (nat n) (toix (nat i))
op 66 ["Nib", ni, n]   = N $ (nat n `shiftR` (4*i)) .&. 0xF  where i = toix (nat ni)
op 66 ["Load8", ni, n] = N $ (nat n `shiftR` (8*i)) .&. 0xFF where i = toix (nat ni)

op 66 ["Store8", i, b, n] = N $ writeByte (nat n) (ix i) (word8 b)
  where ix = toix . nat
        word8 = fromIntegral . (fromIntegral :: Natural -> Word8) . nat

op 66 ["Set", i, n]    = N $ setBit (nat n) (toix (nat i))
op 66 ["Clear", i, n]  = N $ clearBit (nat n) (toix (nat i))
op 66 ["Bex", n]       = N $ bit (toix (nat n))
op 66 ["Trunc8", x]    = N (nat x `mod` 256)
op 66 ["Trunc16", x]   = N (nat x `mod` 65536)
op 66 ["Trunc32", x]   = N (nat x `mod` (2^32))
op 66 ["Trunc64", x]   = N (nat x `mod` (2^64))
op 66 ["Trunc",w,x]    = N (nat x .&. pred (bit $ fromIntegral $ nat w))
  -- TODO: handle oob
op 66 ["Bits", x]      = N $ fromIntegral $ bitWidth (nat x)
op 66 ["Bytes", x]     = N $ fromIntegral $ (bitWidth (nat x) + 7) `div` 8
op 66 ["Unpin", x]     = case x of P _ _ i -> i; _ -> N 0
op 66 ["Seq", x, y]    = x `seq` y
op 66 ["Seq2",x,y,z]   = x `seq` (y `seq` z)
op 66 ["Seq3",a,b,c,d] = a `seq` (b `seq` (c `seq` d))
op 66 ["Sap",f,x]      = x `seq` (f % x)
op 66 ["Sap2",f,x,y]   = x `seq` (y `seq` (f % x % y))
op 66 ["Type", x]      = N $ case x of { P{} -> 1; L{} -> 2; A{} -> 3; N{} -> 0 }
op 66 ["IsPin", n]     = N $ case n of P{} -> 1; _ -> 0
op 66 ["IsLaw", n]     = N $ case n of L{} -> 1; _ -> 0
op 66 ["IsApp", n]     = N $ case n of A{} -> 1; _ -> 0
op 66 ["IsNat", n]     = N $ case n of N{} -> 1; _ -> 0
op 66 ["Nat", n]       = N (nat n)
op 66 ["Arity", x]     = case x of L a _ _ -> N a; _ -> N 0
op 66 ["Name", x]      = case x of L _ m _ -> m;   _ -> N 0
op 66 ["Body", x]      = case x of L _ _ b -> b;   _ -> N 0
op 66 ["Row", h, n, x] = planRow h n x
op 66 ["Rep", h, x, n] = planRep h x n
op 66 ["Slice",o,n,v]  = planSlice o n v
op 66 ["Weld",x,y]     = planWeld x y
op 66 ["Force", x]     = force x
op 66 ["DeepSeq",x,y]  = deepseq x y
op 66 ["Up", i, v, r]  = planUp i v r
op 66 ["UpUniq",i,v,r] = planUp i v r -- TODO: inplace
op 66 ["Coup", h, x]   = planCoup h x
op 66 ["Try", f, x]    = planTry f x
op 66 ["Throw", r]     = throw $! PLAN_EXN $! force r
op 66 ["Hd", r]        = case r of A f _ -> f; x -> x
op 66 ["Ix", i, r]     = planIx i r
op 66 ["Ix0", r]       = ix0 r
op 66 ["Ix1", r]       = ix1 r
op 66 ["Ix2", r]       = op 66 ["Ix", N 2, r]
op 66 ["Ix3", r]       = op 66 ["Ix", N 3, r]
op 66 ["Ix4", r]       = op 66 ["Ix", N 4, r]
op 66 ["Ix5", r]       = op 66 ["Ix", N 5, r]
op 66 ["Ix6", r]       = op 66 ["Ix", N 6, r]
op 66 ["Ix7", r]       = op 66 ["Ix", N 7, r]
op 66 ["Save", x]      = unsafePerformIO (savePin x)
op 66 ["Load", N 0]    = unsafePerformIO loadSnapshot
op 66 ["Trace", x, y]  = trace (showVal x) y
op 66 ["Nil", x]       = planNil x
op 66 ["Truth", x]     = if x == N 0 then N 0 else N 1
op 66 ["Or", x, y]     = if x == N 0 then y   else x
op 66 ["Nor", x, y]    = if x /= N 0 then N 0 else planNil y
op 66 ["And", x, y]    = if x == N 0 then N 0 else y
op 66 ["If", c, t, e]  = if c /= N 0 then t else e
op 66 ["Ifz", c, t, e] = if c == N 0 then t else e
op 66 ["Eq", x, y]     = if nat x == nat y then N 1 else N 0
op 66 ["Ne", x, y]     = if nat x /= nat y then N 1 else N 0
op 66 ["Lt", x, y]     = if nat x <  nat y then N 1 else N 0
op 66 ["Le", x, y]     = if nat x <= nat y then N 1 else N 0
op 66 ["Gt", x, y]     = if nat x >  nat y then N 1 else N 0
op 66 ["Ge", x, y]     = if nat x >= nat y then N 1 else N 0
op 66 ["Cmp", x, y]    = N case compare (nat x) (nat y) of LT->0; EQ->1; GT->2
op 66 ["Sz", x]        = planSz x
op 66 ["Last", x]      = case x of A f x -> V.last x; _ -> N 0
op 66 ["Init", x]      = case x of A f x | length x==1 -> f
                                   A f x               -> A f (V.init x)
                                   _                   -> N 0
op 66 ["Equal",x,y] = planBit (x `deepseq` y `deepseq` (x==y))

op 82 x = unsafePerformIO (rplan x)

op o (x : xs) = error ( "no primop " <> prettyNat o <> " " <> showVal x
                     <> " of size = " <> show (length xs) )

planNil x = if x == N 0 then N 1 else N 0

srcFile :: Natural -> FilePath
srcFile s = ("src" </> natStr s)

rplan :: [Val] -> IO Val
rplan args = do
    readIORef vMode >>= \case
        RPLAN -> pure ()
        BPLAN -> error "Not in RPLAN Mode"
    case args of
        ["Input", n]      -> N . bytesBar <$> BS.hGetSome stdin (toix $ nat n)
        ["Output", x]     -> output stdout x
        ["Warn", x]       -> output stderr x
        ["ReadFile", N p] -> do contents <- BS.readFile (srcFile p)
                                pure $ N $ bytesBar contents
        ["Print", N s]    -> do putStr (natStr s); pure (N 0)
        ["Stamp", N n]    ->
            try (getModificationTime (srcFile n)) <&> \case
                Left (e::IOException) -> N 0
                Right mtime -> N $ fromInteger $ round $ utcTimeToPOSIXSeconds mtime
        ["Now", _]       -> N . fromInteger . round <$> getPOSIXTime
        r                -> error ("rplan:" <> concat (showVal <$> args))

planTry f x = unsafePerformIO do
    try (evaluate $ force $ (%) f x) <&> \case
        Left (PLAN_EXN v) -> adt 1 [v]
        Right v           -> adt 0 [v]

bytesBar :: BS.ByteString -> Natural
bytesBar bs =
    let len = BS.length bs
        body = BS.foldl' (\acc b -> (acc `shiftL` 8) .|. fromIntegral b) 0
                 (BS.reverse bs)
    in body .|. (1 `shiftL` (len * 8))

output :: Handle -> Val -> IO Val
output h x = do
    BS.hPutStr h (natBytes $ nat x)
    hFlush h
    pure (N 0)


planSz :: Val -> Val
planSz (A _ xs) = N $ fromIntegral $ length xs
planSz _        = N 0

planBit True  = N 1
planBit False = N 0

planCoup hd x = case x of
    A f x | arity hd > fromIntegral (length x) -> A hd x
    A f x | otherwise                          -> apple (hd : V.toList x)
    _                                          -> hd

natix = toix . nat

-- TODO: simplify this
planSlice o n obj@(A _ xs) =
    let !onat  = nat o in
    let !nnat  = nat n in
    let !sz    = V.length xs in
    let !sznat = fromIntegral sz in
    if onat > sznat then N 0 else
    let !rsz   = min (sznat - onat) nnat in
    if rsz==0 then N 0 else
    A (N 0) $! V.take (toix rsz) $! V.drop (fromIntegral onat) xs

planSlice o n _ = N 0

planWeld x y = A (N 0) (toRow x <> toRow y)

toRow (A _ xs) = xs
toRow _        = mempty

planRep hd item sz = case nat sz of
    0 -> N $ nat hd
    n -> A (N $ nat hd) $ V.fromList $ take (toix n) (repeat item)

planRow hd sz xs = case nat sz of
    0 -> N $ nat hd
    n -> A (N $ nat hd) $ V.fromList $ take (toix n) (stream xs)
           where stream x = ix0 x : stream (ix1 x)

planUp ix v r = case r of
    A f xs | i < length xs -> A f (xs V.// [(i, v)])
    _                      -> r
  where !i = natix ix


planIx :: Val -> Val -> Val
planIx ix r = case r of A f xs | i < length xs -> xs!i
                        _                      -> N 0
  where !i = natix ix


ix0, ix1 :: Val -> Val
ix0 (A _ x) = x!0;               ix0 _ = N 0
ix1 (A _ x) | length x >1 = x!1; ix1 _ = N 0

adt :: Natural -> [Val] -> Val
adt n [] = N n
adt n xs = A (N n) (V.fromList xs)

array :: [Val] -> Val
array = adt 0

apple :: [Val] -> Val
apple [] = N 0
apple [a] = a
apple (x:y:z) = apple ((x%y):z)

data Mode = BPLAN | RPLAN

vMode :: IORef Mode
vMode = unsafePerformIO $ newIORef BPLAN

-- ── Save ─────────────────────────────────────────────────────────────────────

loadSnapshot :: IO Val
loadSnapshot = error "load ./snap/root.plan"

savePin :: Val -> IO Val
savePin pin@(P hash subPins _) = do
    savePinOnly pin
    let b58 = BS8.unpack (Base58.encodeBase58 Base58.bitcoinAlphabet hash)
    createDirectoryIfMissing False "./snap/"
    writeFile "snap/root.plan" ("@" <> b58 <> "\n")
    pure (N 0)
savePin x = error ("Save: expected a pin, got: " <> showVal x)

savePinOnly :: Val -> IO ()
savePinOnly (P hash subPins inner) = do
    let b58     = BS8.unpack (Base58.encodeBase58 Base58.bitcoinAlphabet hash)
        pinPath = "snap/" <> b58 <> ".plan"
    createDirectoryIfMissing False "./snap/"
    exists <- doesFileExist pinPath
    unless exists do
        mapM_ savePinOnly subPins
        writeFile pinPath (canonize subPins inner)
savePinOnly _ = pure ()
