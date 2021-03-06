{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleInstances #-}
module Network.Wai.Handler.DevelServer
    ( run
    , runQuit
    , runNoWatch
    ) where

import Language.Haskell.Interpreter hiding (typeOf)
import Network.Wai
import Network.HTTP.Types (status200)

import Data.Text.Lazy (pack)
import Data.Text.Lazy.Encoding (encodeUtf8)
import qualified Data.ByteString.Lazy.Char8 as L8
import Control.Exception (Exception, SomeException, toException, fromException)
import qualified Control.Exception as E
import Control.Concurrent (forkIO, threadDelay)

import Data.Maybe
import Control.Monad
import Control.Concurrent.MVar

import System.Directory (getModificationTime)
import qualified Network.Wai.Handler.Warp as Warp
import Network.Wai.Application.Devel
import Network.Wai.Middleware.Debug (debug)

import Data.List (nub, group, sort)
import System.Time (ClockTime)

type FunctionName = String

runNoWatch :: Int -> ModuleName -> FunctionName
           -> (FilePath -> IO [FilePath]) -> IO ()
runNoWatch port modu func extras = do
    ah <- initAppHolder
    _ <- reload modu func extras Nothing ah
    Warp.run port $ toApp ah

runQuit :: Int -> ModuleName -> FunctionName -> (FilePath -> IO [FilePath])
        -> IO ()
runQuit port modu func extras = do
    sig <- newEmptyMVar
    _ <- forkIO $ run port modu func extras (Just sig)
    go sig
  where
    go sig = do
        x <- getLine
        case x of
            'q':_ -> putStrLn "Quitting, goodbye!"
            'r':_ -> do
                putStrLn "Forcing reinterpretation"
                _ <- tryPutMVar sig ()
                go sig
            _ -> go sig

run :: Int -> ModuleName -> FunctionName -> (FilePath -> IO [FilePath]) -> Maybe (MVar ())
    -> IO ()
run port modu func extras msig = do
    ah <- initAppHolder
    _ <- forkIO $ fillApp modu func extras ah msig
    Warp.run port $ toApp ah

{-
startApp :: Queue -> Handler -> IO ()
startApp queue withApp = do
    forkIO (withApp go) >> return ()
  where
    go app = do
        msession <- C.readChan queue
        case msession of
            Nothing -> return ()
            Just (req, onRes) -> do
                void $ forkIO $ (E.handle onErr $ app req) >>= onRes
                go app
    onErr :: SomeException -> IO Response
    onErr e = return
            $ responseLBS
                status500
                [("Content-Type", "text/plain; charset=utf-8")]
            $ charsToLBS
            $ "Exception thrown while running application\n\n" ++ show e
    void x = x >> return ()
-}

getTimes :: [FilePath] -> IO [ClockTime]
getTimes = E.handle (constSE $ return []) . mapM getModificationTime

constSE :: x -> SomeException -> x
constSE = const

fillApp :: String -> String
        -> (FilePath -> IO [FilePath]) -> AppHolder -> Maybe (MVar ()) -> IO ()
fillApp modu func dirs ah msig =
    go Nothing []
  where
    go prevError prevFiles = do
        forceReload <- maybe (return False) (fmap isJust . tryTakeMVar) msig
        toReload <-
            if forceReload || null prevFiles
                then return True
                else do
                    times <- getTimes $ map fst prevFiles
                    return $ times /= map snd prevFiles
        (newError, newFiles) <-
            if toReload
                then reload modu func dirs prevError ah
                else return (prevError, prevFiles)
        threadDelay 1000000
        go newError newFiles

reload :: String -> String
       -> (FilePath -> IO [FilePath])
       -> Maybe SomeException
       -> AppHolder
       -> IO (Maybe SomeException, [(FilePath, ClockTime)])
reload modu func extras prevError ah = do
    case prevError of
         Nothing -> putStrLn "Attempting to interpret your app..."
         _       -> return ()
    loadingApp' prevError ah
    res <- theapp modu func
    case res of
        Left err -> do
            when (show (Just err) /= show prevError) $
               putStrLn $ "Compile failed: " ++ showInterpError err
            loadingApp' (Just $ toException err) ah
            return (Just $ toException err, [])
        Right (app, files') -> E.handle onInitErr $ do
            files'' <- mapM extras files'
            let files = map head $ group $ sort $ concat $ files' : files''
            putStrLn "Interpreting success, new app loaded"
            E.handle onInitErr $ do
                swapApp (\f -> app $ f . debug) ah
                times <- getTimes files
                return (Nothing, zip files times)
    where
        onInitErr e = do
            putStrLn $ "Error initializing application: " ++ show e
            loadingApp' (Just e) ah
            return (Just e, [])

showInterpError :: InterpreterError -> String
showInterpError (WontCompile errs) =
    concat . nub $ map (\(GhcError msg) -> '\n':'\n':msg) errs
showInterpError err = show err

loadingApp' :: Maybe SomeException -> AppHolder -> IO ()
loadingApp' err = swapApp (loadingApp err)

loadingApp :: Maybe SomeException -> Handler
loadingApp err f =
    f $ const $ return $ responseLBS status200
        ( ("Content-Type", "text/plain")
        : case err of
            Nothing -> [("Refresh", "1")]
            Just _ -> []
        ) $ toMessage err
  where
    toMessage Nothing = "Loading code changes, please wait"
    toMessage (Just err') = charsToLBS $ "Error loading code: " ++
        (case fromException err' of
            Just e -> showInterpError e
            Nothing -> show err')

charsToLBS :: String -> L8.ByteString
charsToLBS = encodeUtf8 . pack

type Handler = (Application -> IO ()) -> IO ()

theapp :: String -> String -> IO (Either InterpreterError (Handler, [FilePath]))
theapp modu func =
    runInterpreter $ do
        loadModules [modu]
        mods <- getLoadedModules
        setImports ["Prelude", "Network.Wai", "Data.Enumerator", "Data.ByteString.Internal", modu]
        app <- interpret func infer
        return (app, map toFile mods)
  where
    toFile s = map toSlash s ++ ".hs"
    toSlash '.' = '/'
    toSlash c   = c
