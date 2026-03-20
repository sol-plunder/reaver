-- Copyright (c) 2026 xoCore Technologies, Benjamin Summers
-- SPDX-License-Identifier: MIT
-- See LICENSE for full terms.

-- | A teaching REPL for PlanAssembler.
--
-- Usage from Main.hs:
--
--   import Repl (startRepl)
--   main = startRepl
--
-- Or with an optional preloaded module:
--
--   main = do
--     Repl.preload "src" "prelude"   -- optional
--     Repl.startRepl

{-# LANGUAGE LambdaCase, BlockArguments, OverloadedStrings #-}

module Repl
    ( startRepl
    , preload
    ) where

import System.IO
import System.Exit             (exitSuccess)
import Control.Exception       (try, evaluate, SomeException, displayException)
import Control.DeepSeq         (force)
import Control.Monad           (when, unless)
import Data.IORef              (readIORef, writeIORef)
import Data.Char               (isSpace)
import Data.List               (intercalate)
import Data.Maybe              (fromMaybe)
import Numeric.Natural         (Natural)

import Types
import Print
import Plan                 (vMode, Mode(..), InActor, Rts, withNewRts, rtsEnv, rtsMod)
import Plan                 (Bst(..))
import PlanAssembler

-- ── Public API ────────────────────────────────────────────────────────────────

-- | Optionally preload a .plan module before entering the REPL.
--   e.g. @preload "src" "prelude"@
preload :: InActor => FilePath -> String -> IO ()
preload dir mod = do
    result <- try (loadAssembly dir mod Nothing) :: IO (Either SomeException Val)
    case result of
        Left  e -> hPutStrLn stderr $ "Preload error: " <> show e
        Right _ -> pure ()

-- | Start the interactive REPL.
startRepl :: IO ()
startRepl = withNewRts do
    hSetBuffering stdout NoBuffering
    hSetBuffering stdin  LineBuffering
    mapM_ putStrLn banner
    loop

-- ── Banner ────────────────────────────────────────────────────────────────────

banner :: [String]
banner =
    [ ""
    , "  ┌──────────────────────────────────────┐"
    , "  │     PlanAssembler  Teaching  REPL    │"
    , "  │   :help for commands · :quit to exit  │"
    , "  └──────────────────────────────────────┘"
    , ""
    ]

-- ── Main loop ─────────────────────────────────────────────────────────────────

loop :: InActor => IO ()
loop = readExpr >>= \case
    Nothing   -> putStrLn "\nGoodbye."
    Just ""   -> loop
    Just line -> dispatch line >> loop

-- ── Input: multi-line aware ───────────────────────────────────────────────────

-- | Read one complete expression from stdin.
--   If brackets are left open after the first line the prompt changes to
--   @"... "@ and further lines are collected until the depth closes.
readExpr :: IO (Maybe String)
readExpr = do
    putStr "\nplan> "
    hFlush stdout
    isEOF >>= \case
        True  -> pure Nothing
        False -> do
            line <- getLine
            accumulate line (bracketDepth line)
  where
    accumulate acc depth
        | depth <= 0 = pure . Just . trim $ acc
        | otherwise  = do
            putStr "...   "
            hFlush stdout
            isEOF >>= \case
                True  -> pure . Just . trim $ acc
                False -> do
                    more  <- getLine
                    let acc'   = acc <> "\n" <> more
                        depth' = depth + bracketDepth more
                    accumulate acc' depth'

-- | Count the net bracket depth of a single line, skipping inside strings
--   and after line-comments (@;@).
bracketDepth :: String -> Int
bracketDepth = go 0
  where
    go d []           = d
    go d (';' : _)    = d               -- rest of line is a comment
    go d ('"' : cs)   = skipStr d cs    -- skip string body
    go d ('(' : cs)   = go (d + 1) cs
    go d ('[' : cs)   = go (d + 1) cs
    go d ('{' : cs)   = go (d + 1) cs
    go d (')' : cs)   = go (d - 1) cs
    go d (']' : cs)   = go (d - 1) cs
    go d ('}' : cs)   = go (d - 1) cs
    go d (_   : cs)   = go d cs

    skipStr d []          = d            -- unclosed string: treat as closed
    skipStr d ('"' : cs)  = go d cs
    skipStr d (_   : cs)  = skipStr d cs

trim :: String -> String
trim = reverse . dropWhile isSpace . reverse . dropWhile isSpace

-- ── Dispatch ─────────────────────────────────────────────────────────────────

dispatch :: InActor => String -> IO ()
dispatch (':' : rest) = handleCmd (words rest)
dispatch src          = handleExpr src

-- ── REPL commands ─────────────────────────────────────────────────────────────

handleCmd :: InActor => [String] -> IO ()
handleCmd []                    = pure ()
handleCmd ("quit"  : _)         = putStrLn "Goodbye." >> exitSuccess
handleCmd ("q"     : _)         = putStrLn "Goodbye." >> exitSuccess
handleCmd ("help"  : _)         = putStrLn helpText
handleCmd ("h"     : _)         = putStrLn helpText
handleCmd ("env"   : _)         = cmdEnv
handleCmd ("reset" : _)         = cmdReset
handleCmd ("info"  : nm : _)    = cmdInfo nm
handleCmd ("info"  : _)         = putStrLn "Usage: :info <name>"
handleCmd ("type"  : rest)      = cmdType (unwords rest)
handleCmd ("load"  : d : m : _) = cmdLoad (Just d) m
handleCmd ("load"  : m : _)     = cmdLoad Nothing m
handleCmd ("load"  : _)         = putStrLn "Usage: :load [<srcdir>] <module>"
handleCmd (cmd     : _)         = putStrLn $ "Unknown command :" <> cmd
                                          <> ".  Type :help for a list."

-- ─────────────────────────────────────────────────────────────────────────────

helpText :: String
helpText = unlines
    [ ""
    , "Commands"
    , "────────"
    , "  :help, :h               Show this message"
    , "  :quit, :q               Exit"
    , ""
    , "  :env                    List every name in the current environment"
    , "  :info <name>            Show the value bound to <name>"
    , "  :type <expr>            Evaluate <expr> and show its PLAN kind"
    , "                            (Nat | Law | Pin | App)"
    , "  :load <srcdir> <mod>    Load <srcdir>/<mod>.plan into the environment"
    , "  :reset                  Clear the environment"
    , ""
    , "Expressions"
    , "───────────"
    , "  Any valid PlanAssembler source is accepted directly."
    , "  Multi-line input is supported: keep typing while brackets are open."
    , ""
    , "  42                      A natural number"
    , "  \"hello\"                 A string literal (encoded as a Nat)"
    , "  (#app Add 1 2)          Apply the Add primop  →  3"
    , "  #bind x 99              Bind 99 to the name x"
    , "  #bind double"
    , "    (#law \"double\" (self n)"
    , "       (#app Add n n))    Define a one-argument law and bind it"
    , "  double                  Evaluate a bound name"
    , ""
    , "  Top-level #bind / #macro / #law forms update the live environment,"
    , "  so you can build up definitions interactively just as you would in"
    , "  a .plan source file."
    , ""
    ]

-- ── :env ─────────────────────────────────────────────────────────────────────

cmdEnv :: InActor => IO ()
cmdEnv = do
    env   <- readIORef (rtsEnv ?actorSt)
    let nodes = bstWalk env
    if null nodes
        then putStrLn "(environment is empty)"
        else do
            putStrLn $ show (length nodes) <> " binding(s):\n"
            mapM_ showBinding nodes
  where
    showBinding (Node k _ mac _ _) =
        let tag  = if mac then "  [macro]" else ""
            name = prettyNat k
        in putStrLn $ "  " <> name <> tag
    showBinding Empty = pure ()   -- bstWalk never returns Empty

-- ── :reset ───────────────────────────────────────────────────────────────────

cmdReset :: InActor => IO ()
cmdReset = do
    writeIORef (rtsEnv ?actorSt) Empty
    putStrLn "Environment cleared."

-- ── :info ────────────────────────────────────────────────────────────────────

cmdInfo :: InActor => String -> IO ()
cmdInfo nm = do
    let key = strNat nm
    getenvIO key >>= \case
        Nothing          -> putStrLn $ nm <> " is not bound"
        Just (mac, v, _) -> do
            let tag = if mac then "  [macro]" else ""
            putStrLn $ nm <> " =" <> tag
            putStrLn $ indent (showVal v)
  where
    indent s = unlines $ map ("    " <>) (lines s)

-- ── :type ────────────────────────────────────────────────────────────────────

cmdType :: InActor => String -> IO ()
cmdType src
    | all isSpace src = putStrLn "Usage: :type <expression>"
    | otherwise = do
        result <- try (evalOneSrc src) :: IO (Either SomeException Val)
        case result of
            Left  e -> putStrLn $ "Error: " <> displayException e
            Right v -> putStrLn $ src <> "  ::  " <> planKind v

planKind :: Val -> String
planKind = \case
    P{} -> "Pin"
    L{} -> "Law"
    A{} -> "App"
    N{} -> "Nat"

-- ── :load ────────────────────────────────────────────────────────────────────

-- | Load a module and merge its bindings into the live environment.
--
-- Why not just call loadAssembly and read vEnv afterward?
-- loadAssembly wraps its work in preserveState, which snapshots and
-- *restores* vEnv on exit — right behaviour for the batch driver, but
-- it means every binding the load produced gets thrown away and the
-- pre-call env is put back.
--
-- loadAssembly does however cache each module's env in vMod (which
-- preserveState never touches).  So the correct approach is:
--   1. snapshot the current live env
--   2. let loadAssembly run  (it populates vMod; vEnv is restored to
--      the snapshot when preserveState unwinds)
--   3. read the freshly-cached module env out of vMod
--   4. merge it into the snapshot and write the result back to vEnv
cmdLoad :: InActor => Maybe FilePath -> String -> IO ()
cmdLoad mDir mod = do
    let st = ?actorSt
    liveEnv <- readIORef (rtsEnv st)
    result  <- try (loadAssembly dir mod Nothing) :: IO (Either SomeException Val)
    case result of
        Left e  -> putStrLn $ "Load error: " <> show e
        Right _ -> do
            modCache <- readIORef (rtsMod st)
            case getenv (strNat mod) modCache of
                Nothing -> putStrLn "Load succeeded but module not found in cache."
                Just (_, modEnv, _) -> do
                    writeIORef (rtsEnv st) $! mergeEnv liveEnv modEnv
                    let added = length (bstWalk modEnv)
                    putStrLn $ "Loaded " <> show added <> " binding(s) from "
                             <> dir <> "/" <> mod <> ".plan"
  where
    dir = fromMaybe "src/plan" mDir

-- ── Expression evaluation ─────────────────────────────────────────────────────

handleExpr :: InActor => String -> IO ()
handleExpr src = do
    result <- try (evalAllSrc src) :: IO (Either SomeException [Val])
    case result of
        Left  e  -> putStrLn $ "Error: " <> displayException e
        Right vs -> mapM_ displayVal vs

-- | Evaluate all top-level forms in @src@ and return their results.
evalAllSrc :: InActor => String -> IO [Val]
evalAllSrc src =
    let forms = parseMany src
    in  mapM evalForm forms

-- | Evaluate just the first form, for commands like :type.
evalOneSrc :: InActor => String -> IO Val
evalOneSrc src = case parseMany src of
    []    -> pure (N 0)
    (f:_) -> evalForm f

-- | Expand macros, thunk, and force a single parsed form.
evalForm :: InActor => Val -> IO Val
evalForm form = do
    expo <- macroexpand [] form
    if expo == N 0
        then pure (N 0)
        else evaluate . force =<< thunk expo

-- | Display a result value.
--   N 0 is treated as void / unit and suppressed.
--   A Nat whose nat-string is a readable identifier is shown with a
--   "→ bound" annotation so the user knows a #bind succeeded.
displayVal :: Val -> IO ()
displayVal (N 0) = pure ()          -- void / no-op result
displayVal v@(N n) =
    case natShowStr n of
        Just s  -> putStrLn $ "= " <> showVal v <> "    ; bound name"
        Nothing -> putStrLn $ "= " <> showVal v
displayVal v = putStrLn $ "= " <> showVal v
