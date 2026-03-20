-- Copyright (c) 2026 xoCore Technologies, Benjamin Summers
-- SPDX-License-Identifier: MIT
-- See LICENSE for full terms.

{-# LANGUAGE LambdaCase, ViewPatterns, BlockArguments #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ImplicitParams #-}

module PlanAssembler where

import qualified Data.Vector as V
import qualified Data.List as L

import System.Environment (getArgs)
import Data.Char (isAlphaNum, isDigit, chr)
import Data.Foldable (traverse_)
import Control.Monad (when, unless, void)
import Numeric.Natural (Natural)
import System.IO.Unsafe (unsafePerformIO)
import Data.Vector (Vector)
import Control.DeepSeq (force)
import System.IO (hPutStrLn, hSetBuffering, stdin, stderr, BufferMode(..))
import Data.Vector ((!))
import Control.Exception (evaluate)
import System.FilePath ((</>))

import Data.IORef
import Types
import Print
import Plan

natE :: Natural -> Val
natE n   = A (N 1) $ V.singleton $ N n

symE, strE :: String -> Val
symE s   = N (strNat s)
strE s   = natE (strNat s)

valHd :: Val -> Val
valHd (A f _) = valHd f
valHd x       = x

listE :: [Val] -> Val
listE xs = array xs

curlE :: [Val] -> Val
curlE xs = array (N "#curl" : xs)

brakE :: [Val] -> Val
brakE xs = array (N "#brak" : xs)

data CharType = GAP | SYM | STR | END | NEST ([Val] -> Val)

cat :: Char -> CharType
cat = \case
    { '('  -> NEST listE  ; '[' -> NEST brakE  ; '{' -> NEST curlE
    ; ')'  -> END         ; ']' -> END         ; '}' -> END
    ; '\n' -> GAP         ; ' ' -> GAP         ; ';' -> GAP
    ; '"'  -> STR         ; _   -> SYM
    }

eat :: String -> String
eat (';'  : cs) = eat (dropWhile (/= '\n') cs)
eat (' '  : cs) = eat cs
eat ('\n' : cs) = eat cs
eat cs          = cs

parse :: String -> (Val, String)
parse s0 = case eat s0 of
  [] -> error "eof"
  c:cs ->
    case cat c of
        STR     -> case break (=='"') cs of (body, '"':r) -> (strE body, r)
                                            _             -> error "unterminated string"
        NEST mk -> pseq mk cs
        SYM     -> parseSymbol (c:cs)
        _       -> error ("unexpected: " <> show c)
  where
    parseSymbol xs = let (s, r) = span isSymChar xs in
                     let v = if all isDigit s then natE (read s) else symE s in
                     case r of
                         (cat -> NEST mk):ys ->
                             let (i,s3) = pseq mk ys
                             in (array [N "#juxt", v, i], s3)
                         '"':ys ->
                             let (i,s3) = case break (=='"') ys of
                                    (body, '"':rest) -> (strE body, rest)
                                    _                -> error "unterminated string"
                             in (array [N "#juxt", v, i], s3)
                         _                       -> (v, r)

    isSymChar c = case cat c of SYM -> True; _ -> False

pseq :: ([Val] -> Val) -> String -> (Val, String)
pseq mk str = go [] (' ' : str)
  where
    go :: [Val] -> String -> (Val, String)
    go _   []                   = error "eof in list"
    go acc (c:r) | isCloser c   = (mk (reverse acc), r)
    go _   (c:_) | not (gap c)  = error "bad list"
    go acc cs                   = case eat cs of
        (c:r) | isCloser c -> (mk (reverse acc), r)
        xs2                -> go (a:acc) xs3 where (a, xs3) = parse xs2

    gap :: Char -> Bool
    gap c = c == ' ' || c == '\n' || c == ';'

isCloser :: Char -> Bool
isCloser c = c == ')' || c == ']' || c == '}'

parseMany :: String -> [Val]
parseMany s = case eat s of
    [] -> []
    xs -> n : parseMany rest where (n, rest) = parse xs

bstWalk :: Bst a -> [Bst a]
bstWalk Empty = []
bstWalk node@(Node _ _ _ l r) = bstWalk l <> (node : bstWalk r)

bst :: Bst Val -> Val
bst Empty = N 0
bst (Node k v m l r) = adt k [macroBit m, v, bst l, bst r]
  where macroBit True  = "macro"
        macroBit False = "value"

getenv :: Natural -> Bst a -> Maybe (Bool, a, Bst a)
getenv _   Empty = Nothing
getenv key node@(Node k v m l r) = case compare key k of
  LT -> getenv key l
  EQ -> Just (m, v, node)
  GT -> getenv key r

putenv :: Natural -> a -> Bool -> Bst a -> Bst a
putenv key val mac Empty = Node key val mac Empty Empty
putenv key val mac (Node k v m l r) = case compare key k of
          LT -> Node k v m (putenv key val mac l) r
          EQ -> Node k val mac l r
          GT -> Node k v m l (putenv key val mac r)

getenvIO :: InActor => Natural -> IO (Maybe (Bool, Val, Env))
getenvIO key = getenv key <$> readIORef (rtsEnv ?actorSt)

putEnvIO :: InActor => Natural -> Val -> Bool -> IO ()
putEnvIO key val mac = modifyIORef' (rtsEnv ?actorSt) (putenv key val mac)

eval :: InActor => Val -> IO Val
eval top = macroexpand [] top >>= thunk >>= evaluate

thunk :: InActor => Val -> IO Val
thunk top = case unapp top of
    [N 0]    -> pure (N 0)
    [N 1, x] -> pure x
    [N n]    -> getenvIO n >>= \case
                      Just (_, v, _) -> pure v
                      _              -> unbound "expr" (prettyNat n)
    _        -> fmap apple $ traverse thunk $ listElems "thunk" top

data Macro = PIN | LAW | APP | BIND | MACRO | EXPORT | USER Val

expand1 :: InActor => Macro -> Val -> IO Val
expand1 mac x = do
  case (mac, listElems "expand1" x) of
    (PIN, [_, v]) ->
        (N 1 %) . mkPin <$> eval v

    (LAW, _:tag:sig:forms@(_:_)) ->
        (N 1 %) <$> lawExp tag sig forms

    (BIND, xs@[_, nm, v])  -> do
        !nmNat  <- getNat "bind-key" nm
        !val    <- eval v
        putEnvIO nmNat val False
        -- evaluate $ adt 1 [force val]
        evaluate $ adt 1 [N nmNat]

    (MACRO, xs@[_, nm, v])  -> do
        !nmNat  <- getNat "bind-key" nm
        !val    <- eval v
        putEnvIO nmNat val True
        -- evaluate $ adt 1 [force val]
        evaluate $ adt 1 [N nmNat]

    (APP, _:exprs) -> do
        vs <- traverse eval exprs
        as <- evaluate (apple vs)
        pure $ adt 1 [as]

    (EXPORT, _:syms) -> do
        keys <- traverse (getNat "export") syms
        vals <- traverse getenvIO keys
        writeIORef (rtsEnv ?actorSt) Empty
        flip traverse vals \(Just (_, _, Node k v m _ _)) ->
            putEnvIO k v m
        pure (N 0)

    (USER macVal, _) -> do
        env <- readIORef (rtsEnv ?actorSt)
        pure $! (macVal % bst env % x)

    _ -> error ("bad-form" <> showVal x)

getExpr :: String -> Val -> IO (Vector Val)
getExpr _   (A (N 0) xs) = pure xs
getExpr why val          = error ("bad-" <> why <> ": " <> showVal val)

getNat :: String -> Val -> IO Natural
getNat _   (N n) = pure n
getNat why val   = error ("bad-" <> why <> ": " <> showVal val)

macroexpand :: InActor => Locals -> Val -> IO Val
macroexpand loc = go
  where
    go v = case unapp v of
        -- #(foo) forms are law syntax
        [N 0, "#juxt", "#", x] | not (null loc) -> do
            xo <- macroexpand loc x
            pure $! array ["#juxt", "#", xo]

        N 0 : xs -> getmacro xs >>= \case
                        Nothing  -> array <$> traverse go xs
                        Just mac -> expand1 mac v >>= go
        _        -> pure v

    getmacro = \case N s : _ -> sym s; _ -> pure Nothing

    sym s = do
        env <- readIORef (rtsEnv ?actorSt)
        pure $ case (lookup s loc, getenv s env) of
            (Just{}, _)                 -> Nothing
            (_, Just (True, v, _))      -> Just (USER v)
            (_, Just (False, _, _))     -> Nothing
            (_, Nothing) | s=="#pin"    -> Just PIN
            (_, Nothing) | s=="#law"    -> Just LAW
            (_, Nothing) | s=="#bind"   -> Just BIND
            (_, Nothing) | s=="#macro"  -> Just MACRO
            (_, Nothing) | s=="#app"    -> Just APP
            (_, Nothing) | s=="#export" -> Just EXPORT
            (_, Nothing) | otherwise    -> Nothing

type Locals = [(Natural, Natural)] -- (sym -> refIndex)

lawExp :: InActor => Val -> Val -> [Val] -> IO Val
lawExp tagForm sigForm forms = do
    let (bodySrc, bindForms) = case reverse forms of
            body : revBinds -> (body, reverse revBinds)
            _               -> error "law: missing body"

    !tag <- eval tagForm

    nm : argSyms <- fmap V.toList ( getExpr "sig" sigForm
                                >>= traverse (getNat "arg-name")
                                  )

    binds        <- traverse parseBind bindForms

    let nArgs  = length argSyms
    let locals = buildLocals nm argSyms (map fst binds)

    when (nArgs==0) $ do error "empty argument list"

    bindExps <- traverse (macroexpand locals) (snd <$> binds)
    bodyExp  <- macroexpand locals bodySrc
    bindIRs  <- traverse (compileExpr locals) bindExps
    bodyIR   <- compileExpr locals bodyExp

    pure $ L (fromIntegral nArgs) tag
         $ foldr (\v k -> adt 1 [v,k]) bodyIR bindIRs
  where
    buildLocals :: Natural -> [Natural] -> [Natural] -> Locals
    buildLocals self args binds = (self, 0)
                                : zip args  [1..]
                               ++ zip binds [fromIntegral (length args) + 1 ..]

    parseBind v = case listElems "bind" v of
        ["#juxt", N nm, expr] -> pure (nm, expr)
        _ -> error ("law: bad bind: " <> showVal v)

    ix0 x = case unapp x of _:xs@(_:_) -> last xs; _ -> N 0

listElems :: String -> Val -> [Val]
listElems ctx v = case unapp v of
    N 0 : xs -> xs
    _        -> error (ctx <> ": expected list: " <> showVal v)

lawQuote :: Val -> Val
lawQuote x = array [x]

compileExpr :: InActor => Locals -> Val -> IO Val
compileExpr locals = \case
    N 0       -> pure $ lawQuote (N 0) -- (0 0)
    A (N 1) x -> pure $ lawQuote (x!0) -- (0 x)

    N s -> case lookup s locals of
        Just ix -> pure (N ix)
        Nothing -> getenvIO s >>= \case
            Just (_, gv, _) -> pure (N 0 % gv)   -- embed as constant
            Nothing         -> unbound "law" (prettyNat s)

    x@(A (N 0) xs) -> do
        case V.toList xs of
            ["#juxt", "#", expr] -> eval expr
            _ -> do
                let f:as = V.toList xs
                f'  <- compileExpr locals f
                as' <- traverse (compileExpr locals) as
                pure (foldl (\acc x -> array [acc,x]) f' as')

unbound ctx x = error (ctx <> ": unbound: " <> x)

-- Merge two envs into a balanced BST. New entries shadow old ones.
-- Strategy: walk both trees to sorted lists, merge (new wins on clash),
-- then build a balanced tree from the merged sorted array.
mergeEnv :: Bst a -> Bst a -> Bst a
mergeEnv old new = fromSortedList (mergeSorted (bstToList old) (bstToList new))
  where
    bstToList :: Bst a -> [(Natural, a, Bool)]
    bstToList Empty            = []
    bstToList (Node k v m l r) = bstToList l <> [(k, v, m)] <> bstToList r

    -- Merge two sorted lists; on duplicate key, right (new) wins.
    mergeSorted :: [(Natural, a, Bool)] -> [(Natural, a, Bool)] -> [(Natural, a, Bool)]
    mergeSorted []         ys         = ys
    mergeSorted xs         []         = xs
    mergeSorted xs@(x:xs') ys@(y:ys') =
        case compare (fst3 x) (fst3 y) of
            LT -> x : mergeSorted xs' ys
            EQ -> y : mergeSorted xs' ys'
            GT -> y : mergeSorted xs  ys'
      where fst3 (k, _, _) = k

    -- Build a perfectly balanced BST from a sorted list in O(n).
    fromSortedList :: [(Natural, a, Bool)] -> Bst a
    fromSortedList xs = build (length xs) xs
      where
        build 0 _  = Empty
        build n xs =
            let mid      = n `div` 2
                (ls, rs) = splitAt mid xs
                (k,v,m)  = head rs
            in Node k v m (build mid ls) (build (n - mid - 1) (tail rs))


main :: IO ()
main = withNewRts do
    hSetBuffering stdin LineBuffering
    getArgs >>= void . \case
        d:m:s:as -> loadAssembly d m (Just s) >>= runRepl as
        [d,m]    -> loadAssembly d m Nothing
        _        -> error "usage: wisp module function as ..."

preserveState :: InActor => IO Val -> IO Val
preserveState act = do
    oldMode <- readIORef vMode
    oldEnv  <- readIORef (rtsEnv ?actorSt)
    res <- act
    writeIORef vMode oldMode
    writeIORef (rtsEnv ?actorSt) oldEnv
    pure res

-- Execute a RPLAN procedure.
runRepl :: InActor => [String] -> Val -> IO Val
runRepl args = \case
    v@(P _ _ L{}) -> runReplFn args v
    v@(P _ _ x)   -> runRepl args x -- unpin pinned app
    v             -> runReplFn args v -- unpin pinned app
  where
    runReplFn args fun = do
        preserveState do
           writeIORef (rtsEnv ?actorSt) Empty
           writeIORef vMode RPLAN
           evaluate $ force $ (fun %) $ array $ map (N . strNat) $ args

logStart _mod = pure () -- putStrLn ("<LOAD " <> _mod <> ">")
logCached _mod = pure () -- putStrLn ("cached:" <> _mod)
logFinish _mod = pure () -- putStrLn ("</LOAD " <> _mod <> ">")

loadAssembly :: InActor => FilePath -> String -> Maybe String -> IO Val
loadAssembly srcDir mod mFn = preserveState do
    writeIORef vMode (if srcDir == "snap" then RPLAN else BPLAN)
    writeIORef (rtsEnv ?actorSt) Empty
    processFile mod
    case mFn of
        Nothing -> pure (N 0)
        Just fn -> getenvIO (strNat fn) >>= \case
            Just (_, b, _) -> pure b
            _               -> unbound "program" fn
  where
    processFile mod = do
        let modn = strNat mod
        oldenv <- readIORef (rtsEnv ?actorSt)
        modenv <- loadModule mod
        modifyIORef (rtsMod ?actorSt) $ putenv modn modenv False
        writeIORef (rtsEnv ?actorSt) $! mergeEnv oldenv modenv
        pure ()

    loadModule mod = do
        let modn = strNat mod
        getenv modn <$> readIORef (rtsMod ?actorSt) >>= \case
            Nothing        -> processNewFile mod
            Just (_, v, _) -> logCached mod >> pure v

    processNewFile mod = do
        logStart mod
        writeIORef (rtsEnv ?actorSt) Empty -- process the file in an empty environment
        when (null mod || any (not . okFileChar) mod) do
            error "bad path"
        forms <- parseMany <$> readFile (srcDir </> (mod <> ".plan"))
        traverse_ processForm forms
        logFinish mod
        readIORef (rtsEnv ?actorSt)

    processForm form = case readIncl form of
        Just inc -> processFile inc
        Nothing  -> do
            expo <- macroexpand [] form
            unless (expo == N 0) do
                out <- thunk expo
                hPutStrLn stderr $ force $ showVal out

    okFileChar c = isAlphaNum c || c `elem` ("_-" :: String)

    -- Check if a top-level form is an @include.
    -- The symbol must start with '@', followed by [a-zA-Z0-9_-]+,
    -- and contain no other characters.
    readIncl (N x) = case natStr x of
        '@':cs | not (null cs) && all okFileChar cs -> Just cs
        _ -> Nothing
    readIncl _ = Nothing
