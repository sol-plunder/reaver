-- Copyright (c) 2026 xoCore Technologies, Benjamin Summers
-- SPDX-License-Identifier: MIT
-- See LICENSE for full terms.

{-# LANGUAGE LambdaCase, ViewPatterns, BlockArguments #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveFunctor, DeriveFoldable, DeriveTraversable #-}

module Print where

import Numeric.Natural
import Data.List (intersperse, foldl', sortBy)
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import qualified Data.Set as Set
import Data.Set (Set)
import Data.Bits (shiftR, (.&.))
import GHC.Word (Word8)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BS8
import qualified Data.ByteString.Base58 as Base58
import Control.Monad (unless)
import qualified Data.Vector as V
import Data.Char (isAlpha, isPrint, ord, chr)
import Data.ByteString (ByteString)
import Data.Maybe (fromMaybe)

import Types

-- Decode a Natural to a string (least-significant byte first).
natStr :: Natural -> String
natStr 0 = []
natStr n = chr (fromIntegral (n `mod` 256)) : natStr (n `div` 256)

strNat :: [Char] -> Natural
strNat []     = 0
strNat (c:cs) = fromIntegral (ord c) + (256 * strNat cs)

-- Can this nat be shown as a readable string?
-- Single-byte: must be alphabetic or underscore.
-- Multi-byte: all characters must be printable (not control chars).
natShowStr :: Natural -> Maybe String
natShowStr 0 = Nothing
natShowStr n = let s = natStr n in
    case s of
        [c] | isAlpha c || c == '_' -> Just s
        [_]                         -> Nothing
        _   | all isOk s            -> Just s
            | otherwise             -> Nothing
  where
    isOk '\n' = True
    isOk '"'  = False
    isOk c    = isPrint c && ord c < 128

natBytes :: Natural -> ByteString
natBytes 0 = BS.empty
natBytes n = BS.unfoldr step n
  where
    step x | x < 256 = Nothing
    step x           = Just (fromIntegral (x .&. 0xFF), x `shiftR` 8)

prettyNat :: Natural -> String
prettyNat n = maybe (show n) show (natShowStr n)

-- Generate sequential local names: a, b, …, z, aa, ab, …
genLocal :: Int -> String
genLocal i
  | i < 26    = [chr (ord 'a' + i)]
  | otherwise = genLocal (i `div` 26 - 1) ++ [chr (ord 'a' + i `mod` 26)]

-- ── Intermediate representation ──────────────────────────────────────────────
--
-- Printing is split into passes, each refining a single type parameter `r`:
--
--   extract   :: Val       -> Doc Ref0    -- decode Val; pins=R0Pin, vars=R0Var
--   nameSelf  :: Doc Ref0  -> Doc Ref1    -- replace R0Var 0 with R1Self at each law
--   nameGlobal:: Doc Ref1  -> Doc Ref2    -- resolve pins and promote R1Self -> R2Named
--   nameVars  :: Doc Ref2  -> Doc String  -- fill remaining R2Var with short names
--   render    :: Int -> Doc String -> String

type Hash  = BS.ByteString
type VarIx = Int

-- | A pinned law reference carrying the hash and the tag-derived name hint.
data GlobalRef = GlobalRef
    { grName :: Maybe String
    , grHash :: Hash
    } deriving (Show)

-- Phase-0: raw output of extract.
data Ref0
    = R0Pin GlobalRef   -- a pinned law reference
    | R0Var VarIx       -- any local variable (self, arg, or let), still a raw index
    deriving (Show)

-- Phase-1: after nameSelf; self-bindings carry their tag-derived name.
data Ref1
    = R1Pin GlobalRef   -- still-unresolved pin
    | R1Self String     -- self reference, named from law tag
    | R1Var VarIx       -- arg or let variable, still a raw index
    deriving (Show)

-- Phase-2: after nameGlobal; all named references are strings.
data Ref2
    = R2Named String    -- fully resolved: was R1Pin or R1Self
    | R2Var VarIx       -- arg or let variable, still needs a short name
    deriving (Show)

-- Phase-3: Doc String — plain fmap over Ref2 fills all remaining vars.

data Doc r
    = DNum     Natural
    | DStr     String
    | DRef     r
    | DPin     (Doc r)
    | DLaw     (LawDoc r)
    | DApp     (Doc r) [Doc r]
    deriving (Functor, Foldable, Traversable)

data LawDoc r = LawDoc
    { ldTag     :: Doc r        -- rendered tag nat, for display
    , ldTagHint :: Maybe String -- readable name derived from tag nat, for self-naming
    , ldSelf    :: r
    , ldArgs    :: [r]
    , ldLets    :: [(r, Expr r)]
    , ldBody    :: Expr r
    } deriving (Functor, Foldable, Traversable)

data Expr r
    = EVar     r
    | EConst   (Doc r)
    | EApp     (Expr r) (Expr r)
    | EEscaped (Doc r)
    deriving (Functor, Foldable, Traversable)

-- ── Pass 1: extract ──────────────────────────────────────────────────────────

extract :: Val -> Doc Ref0
extract (N n) = case natShowStr n of
    Just s  -> DStr s
    Nothing -> DNum n
extract (P h _ x@N{})     = DPin (extract x)
extract (P h _ (L _ m _)) = DRef (R0Pin (GlobalRef (tagName m) h))
extract (P h _ _)         = DRef (R0Pin (GlobalRef Nothing h))
extract (L a m b)         = DLaw (extractLaw a m b)
extract (A f     xs)      = DApp (extract f) (map extract (V.toList xs))

tagName :: Val -> Maybe String
tagName (N m) = natShowStr m
tagName _     = Nothing

extractLaw :: Natural -> Val -> Val -> LawDoc Ref0
extractLaw arity tag body = LawDoc
    { ldTag     = extract tag
    , ldTagHint = tagName tag
    , ldSelf    = R0Var 0
    , ldArgs    = map (R0Var . fromIntegral) [1 .. arity]
    , ldLets    = zip (map (R0Var . fromIntegral) [arity + 1 ..])
                      (map (extractExpr maxref) letVals)
    , ldBody    = extractExpr maxref bodyVal
    }
  where
    (letVals, bodyVal) = peelLets body
    maxref             = fromIntegral arity + length letVals

peelLets :: Val -> ([Val], Val)
peelLets = go []
  where
    go acc x = case unapp x of
        [N 1, v, k] -> go (v : acc) k
        _           -> (reverse acc, x)

extractExpr :: Int -> Val -> Expr Ref0
extractExpr maxref = goExpr
  where
    goExpr = goApp []

    goApp acc v = case unapp v of
        [N 0, f, x] -> goApp (goExpr x : acc) f
        _           -> foldl EApp (goHead v) acc

    goHead v = case unapp v of
        [N i] | i <= fromIntegral maxref -> EVar (R0Var (fromIntegral i))
        [N 0, c]                         -> EConst (extract c)
        _                                -> EEscaped (extract v)

-- ── Pass 2: nameSelf ─────────────────────────────────────────────────────────

nameSelf :: Doc Ref0 -> Doc Ref1
nameSelf = goDoc
  where
    goDoc (DNum n)       = DNum n
    goDoc (DStr s)       = DStr s
    goDoc (DRef r)       = DRef (case r of { R0Pin g -> R1Pin g; R0Var i -> R1Var i })
    goDoc (DPin d)       = DPin (goDoc d)
    goDoc (DLaw law)     = DLaw (goLaw law)
    goDoc (DApp f xs)    = DApp (goDoc f) (map goDoc xs)

    goLaw (LawDoc tag hint _ args lets body) =
        let selfName = fromMaybe "self" hint
            sub r = case r of
                R0Pin g -> R1Pin g
                R0Var 0 -> R1Self selfName
                R0Var i -> R1Var i
        in LawDoc
            { ldTag     = nameSelf tag
            , ldTagHint = hint
            , ldSelf    = R1Self selfName
            , ldArgs    = map sub args
            , ldLets    = map (\(b, e) -> (sub b, goExpr sub e)) lets
            , ldBody    = goExpr sub body
            }

    goExpr sub (EVar r)       = EVar (sub r)
    goExpr sub (EApp f x)     = EApp (goExpr sub f) (goExpr sub x)
    goExpr sub (EConst doc)   = EConst (goDoc doc)
    goExpr sub (EEscaped doc) = EEscaped (goDoc doc)

-- ── Pass 3: nameGlobal ───────────────────────────────────────────────────────

nameGlobal :: Doc Ref1 -> Doc Ref2
nameGlobal doc = fmap promote doc
  where
    allRefs :: [Ref1]
    allRefs = foldr (:) [] doc

    selfNames :: Set String
    selfNames = Set.fromList [ s | R1Self s <- allRefs ]

    uniqueGlobals :: Map Hash (Maybe String)
    uniqueGlobals = Map.fromList [ (grHash g, grName g) | R1Pin g <- allRefs ]

    globalTable :: Map Hash String
    globalTable = assignGlobalNames selfNames uniqueGlobals

    promote :: Ref1 -> Ref2
    promote (R1Pin g)  = R2Named (globalTable Map.! grHash g)
    promote (R1Self s) = R2Named s
    promote (R1Var  i) = R2Var i

assignGlobalNames :: Set String -> Map Hash (Maybe String) -> Map Hash String
assignGlobalNames reserved globals = namedResult <> unnamedResult
  where
    namedGroups :: [(String, [Hash])]
    namedGroups = Map.toAscList
                $ Map.fromListWith (<>)
                    [ (n, [h]) | (h, Just n) <- Map.toList globals ]

    unnamedHashes :: [Hash]
    unnamedHashes = sortBy compare [ h | (h, Nothing) <- Map.toList globals ]

    (namedResult, used1) =
        foldl' assignGroup (Map.empty, reserved) namedGroups

    (unnamedResult, _) =
        foldl' assignUnnamed (Map.empty, used1) unnamedHashes

    assignGroup (acc, used) (hint, hashes) =
        foldl' (\(a, u) h ->
                    let n = freshName hint u
                    in (Map.insert h n a, Set.insert n u))
               (acc, used)
               (sortBy compare hashes)

    assignUnnamed (acc, used) h =
        let base = "<" <> take 8 (BS8.unpack (Base58.encodeBase58 Base58.bitcoinAlphabet h)) <> ">"
            n    = freshName base used
        in (Map.insert h n acc, Set.insert n used)

    freshName :: String -> Set String -> String
    freshName base used =
        head $ filter (`Set.notMember` used)
             $ base : [ base <> "_" <> show i | i <- [2 :: Int ..] ]

    renderHash :: Hash -> String
    renderHash = concatMap hexByte . BS.unpack

    hexByte :: Word8 -> String
    hexByte b = [hexDigit (fromIntegral b `shiftR` 4), hexDigit (fromIntegral b .&. 0xF)]

    hexDigit :: Int -> Char
    hexDigit n = "0123456789abcdef" !! n

-- ── Pass 4: nameVars ─────────────────────────────────────────────────────────

nameVars :: Doc Ref2 -> Doc String
nameVars doc = fst (goDoc 0 doc)
  where
    reserved :: Set String
    reserved = Set.fromList [ s | R2Named s <- foldr (:) [] doc ]

    nextFresh :: Int -> (String, Int)
    nextFresh nc
        | genLocal nc `Set.notMember` reserved = (genLocal nc, nc + 1)
        | otherwise                             = nextFresh (nc + 1)

    goDoc :: Int -> Doc Ref2 -> (Doc String, Int)
    goDoc nc (DNum n)    = (DNum n, nc)
    goDoc nc (DStr s)    = (DStr s, nc)
    goDoc nc (DRef r)    = (DRef (resolveRef Map.empty r), nc)
    goDoc nc (DPin d)    = let (d', nc') = goDoc nc d in (DPin d', nc')
    goDoc nc (DLaw law)  = let (law', nc') = goLaw nc law in (DLaw law', nc')
    goDoc nc (DApp f xs) =
        let (f',  nc1) = goDoc nc f
            (xs', nc2) = goDocList nc1 xs
        in (DApp f' xs', nc2)

    goDocList :: Int -> [Doc Ref2] -> ([Doc String], Int)
    goDocList nc []     = ([], nc)
    goDocList nc (d:ds) =
        let (d',  nc1) = goDoc nc d
            (ds', nc2) = goDocList nc1 ds
        in (d':ds', nc2)

    goLaw :: Int -> LawDoc Ref2 -> (LawDoc String, Int)
    goLaw nc (LawDoc tag hint self args lets body) =
        let (tag',     nc_tag)        = goDoc nc tag
            (self',    nc0, tbl0) = claimRef nc_tag Map.empty self
            (args',    nc1, tbl1) = claimList nc0 tbl0 args
            (binders, rhss)       = unzip lets
            (binders', nc2, tbl2) = claimList nc1 tbl1 binders
            (rhss', nc3)          = goExprList tbl2 nc2 rhss
            (body', nc4)          = goExpr tbl2 nc3 body
        in (LawDoc tag' hint self' args' (zip binders' rhss') body', nc4)
      where
        claimList n tbl rs =
            foldl' (\(acc, n', tbl') r ->
                        let (s, n'', tbl'') = claimRef n' tbl' r
                        in (acc <> [s], n'', tbl''))
                   ([], n, tbl) rs

    goExpr :: Map VarIx String -> Int -> Expr Ref2 -> (Expr String, Int)
    goExpr tbl nc (EVar r)       = (EVar (resolveRef tbl r), nc)
    goExpr tbl nc (EApp f x)     =
        let (f', nc1) = goExpr tbl nc  f
            (x', nc2) = goExpr tbl nc1 x
        in (EApp f' x', nc2)
    goExpr tbl nc (EConst doc)   =
        let (doc', nc') = goDoc nc doc in (EConst doc', nc')
    goExpr tbl nc (EEscaped doc) =
        let (doc', nc') = goDoc nc doc in (EEscaped doc', nc')

    goExprList :: Map VarIx String -> Int -> [Expr Ref2] -> ([Expr String], Int)
    goExprList tbl nc []     = ([], nc)
    goExprList tbl nc (e:es) =
        let (e',  nc1) = goExpr tbl nc  e
            (es', nc2) = goExprList tbl nc1 es
        in (e':es', nc2)

    claimRef :: Int -> Map VarIx String -> Ref2 -> (String, Int, Map VarIx String)
    claimRef nc tbl (R2Named s) = (s,    nc,   tbl)
    claimRef nc tbl (R2Var   i) = (name, nc'', Map.insert i name tbl)
      where (name, nc'') = nextFresh nc

    resolveRef :: Map VarIx String -> Ref2 -> String
    resolveRef _   (R2Named s) = s
    resolveRef tbl (R2Var   i) = case Map.lookup i tbl of
        Just s  -> s
        Nothing -> error ("nameVars: unbound R2Var " <> show i)

-- ── Top-level entry points ───────────────────────────────────────────────────

showVal :: Val -> String
showVal = prettyValMulti 50

prettyValMulti :: Int -> Val -> String
prettyValMulti maxW val =
    case val of
        P _ _ inner -> render maxW (DApp (DRef "#pin") [pipeline inner])
        _           -> render maxW (pipeline val)
  where
    pipeline = nameVars . nameGlobal . nameSelf . extract

-- ── Renderer ─────────────────────────────────────────────────────────────────
--
-- Operates on Doc String: all names already resolved, all structure decoded.
-- Tries flat layout first; falls back to wide (2-space indent) if too long.

render :: Int -> Doc String -> String
render maxW = pp 0
  where
    step = 2 :: Int
    nl col = '\n' : replicate col ' '

    isDelimited ('(':_) = True
    isDelimited ('[':_) = True
    isDelimited ('{':_) = True
    isDelimited _       = False

    pp :: Int -> Doc String -> String
    pp col d =
        let flat = ppFlat d
        in if length flat <= maxW then flat else ppWide col d

    -- ── Flat ─────────────────────────────────────────────────────────────────

    ppFlat :: Doc String -> String
    ppFlat (DNum n)    = show n
    ppFlat (DStr s)    = show s
    ppFlat (DRef name) = name
    ppFlat (DPin d)    = "(#pin " <> ppFlat d <> ")"
    ppFlat (DLaw law)  = flatLaw law
    ppFlat (DApp f xs) = "(" <> ppFlat f <> " " <> unwords (map ppFlat xs) <> ")"

    flatLaw :: LawDoc String -> String
    flatLaw (LawDoc tag _ self args lets body) =
        let sig     = "(" <> unwords (self : args) <> ")"
            letStrs = concatMap (\(nm, e) -> " " <> nm <> wrap (flatExpr e)) lets
        in "(#law " <> ppFlat tag <> " " <> sig <> letStrs <> " " <> flatExpr body <> ")"

    wrap :: String -> String
    wrap s@('(':_) = s
    wrap s         = '(' : s <> ")"

    flatExpr :: Expr String -> String
    flatExpr e = goApp [] e
      where
        goApp acc (EApp f x) = goApp (x : acc) f
        goApp acc hd = case acc of
            [] -> goHead hd
            _  -> "(" <> goHead hd <> concatMap (\a -> " " <> flatExpr a) acc <> ")"

        goHead (EVar name)              = name
        goHead (EConst (DApp f xs))     = "(#app " <> ppFlat f <> concatMap (\x -> " " <> ppFlat x) xs <> ")"
        goHead (EConst doc)             = ppFlat doc
        goHead (EEscaped doc)           = let s = ppFlat doc
                                          in if isDelimited s then '#' : s else "#(" <> s <> ")"
        goHead (EApp _ _)               = error "render: impossible EApp at head"

    -- ── Wide ─────────────────────────────────────────────────────────────────

    ppWide :: Int -> Doc String -> String
    ppWide _   (DNum n)    = show n
    ppWide _   (DStr s)    = show s
    ppWide _   (DRef name) = name
    ppWide col (DPin d)    = "(#pin " <> pp (col + 6) d <> ")"
    ppWide col (DLaw law)  = wideLaw col law
    ppWide col (DApp f xs) = wideApp col f xs

    -- Greedily take Doc items while their flat rendering fits the budget.
    takeFitting :: Int -> [Doc String] -> ([Doc String], [Doc String])
    takeFitting _ [] = ([], [])
    takeFitting n (x:xs) =
        let len = length (ppFlat x)
        in if len > n then ([], x:xs)
           else let (taken, left) = takeFitting (n - len - 1) xs
                in (x:taken, left)

    -- Render Doc args across lines, packing small items greedily.
    -- Large items (too big to pack) are forced wide, not flat.
    packLines :: Int -> [Doc String] -> String
    packLines _   [] = ""
    packLines col xs =
        let (inline, rest) = takeFitting (maxW - col) xs
        in case inline of
            [] -> nl col <> ppWide col (head xs) <> packLines col (tail xs)
            _  -> nl col <> unwords (map ppFlat inline) <> packLines col rest

    wideApp :: Int -> Doc String -> [Doc String] -> String
    wideApp col f xs =
        let col'           = col + step
            sf             = pp (col + 1) f
            budget         = maxW - col' - length sf
            (inline, rest) = takeFitting budget xs
            first          = case (inline, rest) of
                ([], [])  -> ""
                ([], _)   -> nl col' <> ppWide col' (head rest) <> packLines col' (tail rest)
                _         -> " " <> unwords (map ppFlat inline) <> packLines col' rest
        in "(" <> sf <> first <> ")"


    wideLaw :: Int -> LawDoc String -> String
    wideLaw col (LawDoc tag _ self args lets body) =
        let col'     = col + step
            sig      = "(" <> unwords (self : args) <> ")"
            header   = "(#law " <> pp (col + 6) tag <> " " <> sig
            letStrs  = concatMap (\(nm, e) -> " " <> nm <> wrap (flatExpr e)) lets
            flatBody = letStrs <> " " <> flatExpr body
        in if col + length header + length flatBody + 1 <= maxW
           then header <> flatBody <> ")"
           else header <> wideLawBody col' lets body <> ")"

    wideLawBody :: Int -> [(String, Expr String)] -> Expr String -> String
    wideLawBody col lets body =
        concatMap wideLet lets <> nl col <> wideExpr col body
      where
        wideLet (nm, e) = nl col <> nm <> bwrap (wideExpr (col + length nm) e)
        bwrap s@('(':_) = s
        bwrap s         = '(' : s <> ")"

    wideExpr :: Int -> Expr String -> String
    wideExpr ec e = goApp [] e
      where
        goApp acc (EApp f x) = goApp (x : acc) f
        goApp acc hd = case acc of
            [] -> wideHead ec hd
            _  ->
                let flat = "(" <> flatHead hd <> concatMap (\a -> " " <> flatExpr a) acc <> ")"
                in if length flat <= maxW
                   then flat
                   else let col'           = ec + step
                            sh             = wideHead (ec + 1) hd
                            budget         = maxW - col' - length sh
                            (inline, rest) = takeExprs budget acc
                            first          = case (inline, rest) of
                                ([], [])  -> ""
                                ([], _)   -> nl col' <> wideExpr col' (head rest)
                                                     <> packExprs col' (tail rest)
                                _         -> " " <> unwords (map flatExpr inline)
                                                  <> packExprs col' rest
                        in "(" <> sh <> first <> ")"

        -- Greedily take Expr items while their flat rendering fits the budget.
        takeExprs :: Int -> [Expr String] -> ([Expr String], [Expr String])
        takeExprs _ [] = ([], [])
        takeExprs n (x:xs) =
            let len = length (flatExpr x)
            in if len > n then ([], x:xs)
               else let (taken, left) = takeExprs (n - len - 1) xs
                    in (x:taken, left)

        -- Render Expr args across lines, packing small items greedily.
        -- Large items are rendered wide, not flat.
        packExprs :: Int -> [Expr String] -> String
        packExprs _   [] = ""
        packExprs col xs =
            let (inline, rest) = takeExprs (maxW - col) xs
            in case inline of
                [] -> nl col <> wideExpr col (head xs) <> packExprs col (tail xs)
                _  -> nl col <> unwords (map flatExpr inline) <> packExprs col rest


        flatHead (EVar name)          = name
        flatHead (EConst (DApp f xs)) = "(#app " <> ppFlat f <> concatMap (\x -> " " <> ppFlat x) xs <> ")"
        flatHead (EConst doc)         = ppFlat doc
        flatHead (EEscaped doc)       = let s = ppFlat doc
                                        in if isDelimited s then '#' : s else "#(" <> s <> ")"
        flatHead (EApp _ _)           = error "render: impossible EApp at flatHead"

        wideHead ec' (EVar name)          = name
        wideHead ec' (EConst (DApp f xs)) =
            let col' = ec' + step
                flat = "(#app " <> ppFlat f <> concatMap (\x -> " " <> ppFlat x) xs <> ")"
            in if ec' + length flat <= maxW
               then flat
               else "(#app " <> pp (ec' + 6) f
                    <> concatMap (\x -> nl col' <> pp col' x) xs <> ")"
        wideHead ec' (EConst doc)         = pp ec' doc
        wideHead ec' (EEscaped doc)       =
            let s = ppFlat doc
            in if isDelimited s
               then '#' : pp (ec' + 1) doc
               else "#(" <> pp (ec' + 2) doc <> ")"
        wideHead _ (EApp _ _) = error "render: impossible EApp at wideHead"

-- ── Canonicalize ─────────────────────────────────────────────────────────────

canonize :: [Val] -> Val -> String
canonize _pins v = intercalate "\n" (importLines <> [bindLine, exportLine])
  where
    inner      = case v of P _ _ i -> i; _ -> v
    doc0       = extract inner
    doc        = nameVars . nameGlobal . nameSelf $ doc0

    globals    = orderedGlobals doc0

    allRefs    = foldr (:) [] (nameSelf doc0)
    selfNames  = Set.fromList [ s | R1Self s <- allRefs ]
    uniqueGlob = Map.fromList [ (grHash g, grName g) | R0Pin g <- foldr (:) [] doc0 ]
    nameTable  = assignGlobalNames selfNames uniqueGlob

    hashToB58 :: Hash -> String
    hashToB58 h = BS8.unpack (Base58.encodeBase58 Base58.bitcoinAlphabet h)

    importLines :: [String]
    importLines = concatMap importFor globals
      where
        importFor g =
            let name = Map.findWithDefault (hashToB58 (grHash g)) (grHash g) nameTable
            in ["@" <> hashToB58 (grHash g) <> " (#bind " <> name <> " _)"]

    bindDoc    = DApp (DRef "#bind")
                      [ DRef "_"
                      , DApp (DRef "#pin") [doc]
                      ]
    bindLine   = render 80 bindDoc
    exportLine = "(#export _)\n"

    intercalate sep xs = concat (intersperse sep xs)

-- ── Globals traversal ────────────────────────────────────────────────────────

orderedGlobals :: Doc Ref0 -> [GlobalRef]
orderedGlobals doc = snd $ foldl' step (Set.empty, []) (globalsInOrder doc)
  where
    step (seen, acc) g
        | Set.member (grHash g) seen = (seen, acc)
        | otherwise                  = (Set.insert (grHash g) seen, acc <> [g])

globalsInOrder :: Doc Ref0 -> [GlobalRef]
globalsInOrder = goDoc
  where
    goDoc (DRef (R0Pin g)) = [g]
    goDoc (DRef _)         = []
    goDoc (DNum _)         = []
    goDoc (DStr _)         = []
    goDoc (DPin _)         = []
    goDoc (DApp f xs)      = goDoc f <> concatMap goDoc xs
    goDoc (DLaw law)       = goLaw law

    goLaw (LawDoc tag _ _ _ lets body) =
        goDoc tag <> concatMap (goExpr . snd) lets <> goExpr body

    goExpr (EVar _)       = []
    goExpr (EApp f x)     = goExpr f <> goExpr x
    goExpr (EConst doc)   = goDoc doc
    goExpr (EEscaped doc) = goDoc doc
