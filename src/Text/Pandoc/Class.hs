{-# LANGUAGE DeriveFunctor, DeriveDataTypeable, TypeSynonymInstances,
FlexibleInstances, GeneralizedNewtypeDeriving, FlexibleContexts #-}

{-
Copyright (C) 2016 Jesse Rosenthal <jrosenthal@jhu.edu>

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
-}

{- |
   Module      : Text.Pandoc.Class
   Copyright   : Copyright (C) 2016 Jesse Rosenthal
   License     : GNU GPL, version 2 or above

   Maintainer  : Jesse Rosenthal <jrosenthal@jhu.edu>
   Stability   : alpha
   Portability : portable

Typeclass for pandoc readers and writers, allowing both IO and pure instances.
-}

module Text.Pandoc.Class ( PandocMonad(..)
                         , CommonState(..)
                         , PureState(..)
                         , getPOSIXTime
                         , getZonedTime
                         , warning
                         , warningWithPos
                         , getWarnings
                         , getMediaBag
                         , setMediaBag
                         , insertMedia
                         , getInputFiles
                         , getOutputFile
                         , PandocIO(..)
                         , PandocPure(..)
                         , FileInfo(..)
                         , runIO
                         , runIOorExplode
                         , runPure
                         , withMediaBag
                         , withWarningsToStderr
                         ) where

import Prelude hiding (readFile, fail)
import qualified Control.Monad as M (fail)
import System.Random (StdGen, next, mkStdGen)
import qualified System.Random as IO (newStdGen)
import Codec.Archive.Zip (Archive, fromArchive, emptyArchive)
import Data.Unique (hashUnique)
import qualified Data.Unique as IO (newUnique)
import qualified Text.Pandoc.Shared as IO ( fetchItem
                                          , fetchItem'
                                          , getDefaultReferenceDocx
                                          , getDefaultReferenceODT
                                          , readDataFile
                                          , warn)
import Text.Pandoc.Compat.Time (UTCTime)
import Text.Pandoc.Parsing (ParserT, ParserState, SourcePos)
import qualified Text.Pandoc.Compat.Time as IO (getCurrentTime)
import Data.Time.Clock.POSIX ( utcTimeToPOSIXSeconds
                             , posixSecondsToUTCTime
                             , POSIXTime )
import Data.Time.LocalTime (TimeZone, ZonedTime, utcToZonedTime, utc)
import qualified Data.Time.LocalTime as IO (getCurrentTimeZone)
import Text.Pandoc.MIME (MimeType, getMimeType)
import Text.Pandoc.MediaBag (MediaBag)
import qualified Text.Pandoc.MediaBag as MB
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL
import qualified Control.Exception as E
import qualified System.Environment as IO (lookupEnv)
import System.FilePath.Glob (match, compile)
import System.FilePath ((</>))
import qualified System.FilePath.Glob as IO (glob)
import qualified System.Directory as IO (getModificationTime)
import Control.Monad.State hiding (fail)
import Control.Monad.Except hiding (fail)
import Data.Word (Word8)
import Data.Default
import System.IO.Error
import qualified Data.Map as M
import Text.Pandoc.Error

class (Functor m, Applicative m, Monad m, MonadError PandocError m, MonadState CommonState m) => PandocMonad m where
  lookupEnv :: String -> m (Maybe String)
  getCurrentTime :: m UTCTime
  getCurrentTimeZone :: m TimeZone
  getDefaultReferenceDocx :: Maybe FilePath -> m Archive
  getDefaultReferenceODT :: Maybe FilePath -> m Archive
  newStdGen :: m StdGen
  newUniqueHash :: m Int
  readFileLazy :: FilePath -> m BL.ByteString
  readDataFile :: Maybe FilePath
               -> FilePath
               -> m B.ByteString
  fetchItem :: Maybe String
            -> String
            -> m (Either E.SomeException (B.ByteString, Maybe MimeType))
  fetchItem' :: MediaBag
             -> Maybe String
             -> String
             -> m (Either E.SomeException (B.ByteString, Maybe MimeType))
  fail :: String -> m b
  glob :: String -> m [FilePath]
  getModificationTime :: FilePath -> m UTCTime

  

-- Functions defined for all PandocMonad instances

warning :: PandocMonad m => String -> m ()
warning msg = modify $ \st -> st{stWarnings = msg : stWarnings st}

getWarnings :: PandocMonad m => m [String]
getWarnings = gets stWarnings

setMediaBag :: PandocMonad m => MediaBag -> m ()
setMediaBag mb = modify $ \st -> st{stMediaBag = mb}

getMediaBag :: PandocMonad m => m MediaBag
getMediaBag = gets stMediaBag

insertMedia :: PandocMonad m => FilePath -> Maybe MimeType -> BL.ByteString -> m ()
insertMedia fp mime bs =
    modify $ \st -> st{stMediaBag = MB.insertMedia fp mime bs (stMediaBag st) }

getInputFiles :: PandocMonad m => m (Maybe [FilePath])
getInputFiles = gets stInputFiles

getOutputFile :: PandocMonad m => m (Maybe FilePath)
getOutputFile = gets stOutputFile

getPOSIXTime :: (PandocMonad m) => m POSIXTime
getPOSIXTime = utcTimeToPOSIXSeconds <$> getCurrentTime

getZonedTime :: (PandocMonad m) => m ZonedTime
getZonedTime = do
  t <- getCurrentTime
  tz <- getCurrentTimeZone
  return $ utcToZonedTime tz t

warningWithPos :: PandocMonad m
               => Maybe SourcePos
               -> String
               -> ParserT [Char] ParserState m ()
warningWithPos mbpos msg =
  lift $ warning $ msg ++ maybe "" (\pos -> " " ++ show pos) mbpos

--

-- All PandocMonad instances should be an instance MonadState of this
-- datatype:

data CommonState = CommonState { stWarnings :: [String]
                               , stMediaBag :: MediaBag
                               , stInputFiles :: Maybe [FilePath]
                               , stOutputFile :: Maybe FilePath
                               }

instance Default CommonState where
  def = CommonState { stWarnings = []
                    , stMediaBag = mempty
                    , stInputFiles = Nothing
                    , stOutputFile = Nothing
                    }

runIO :: PandocIO a -> IO (Either PandocError a)
runIO ma = flip evalStateT def $ runExceptT $ unPandocIO ma

withMediaBag :: PandocMonad m => m a ->  m (a, MediaBag)
withMediaBag ma = ((,)) <$> ma <*> getMediaBag

withWarningsToStderr :: PandocIO a -> PandocIO a
withWarningsToStderr f = do
  x <- f
  getWarnings >>= mapM_ IO.warn
  return x

runIOorExplode :: PandocIO a -> IO a
runIOorExplode ma = runIO ma >>= handleError

newtype PandocIO a = PandocIO {
  unPandocIO :: ExceptT PandocError (StateT CommonState IO) a
  } deriving ( MonadIO
             , Functor
             , Applicative
             , Monad
             , MonadState CommonState
             , MonadError PandocError
             )

instance PandocMonad PandocIO where
  lookupEnv = liftIO . IO.lookupEnv
  getCurrentTime = liftIO IO.getCurrentTime
  getCurrentTimeZone = liftIO IO.getCurrentTimeZone
  getDefaultReferenceDocx = liftIO . IO.getDefaultReferenceDocx
  getDefaultReferenceODT = liftIO . IO.getDefaultReferenceODT
  newStdGen = liftIO IO.newStdGen
  newUniqueHash = hashUnique <$> (liftIO IO.newUnique)
  readFileLazy s = do
    eitherBS <- liftIO (tryIOError $ BL.readFile s)
    case eitherBS of
      Right bs -> return bs
      Left _ -> throwError $ PandocFileReadError s
  -- TODO: Make this more sensitive to the different sorts of failure
  readDataFile mfp fname = do
    eitherBS <- liftIO (tryIOError $ IO.readDataFile mfp fname)
    case eitherBS of
      Right bs -> return bs
      Left _ -> throwError $ PandocFileReadError fname
  fail = M.fail
  fetchItem ms s = liftIO $ IO.fetchItem ms s
  fetchItem' mb ms s = liftIO $ IO.fetchItem' mb ms s
  glob = liftIO . IO.glob
  getModificationTime fp = do
    eitherMtime <- liftIO (tryIOError $ IO.getModificationTime fp)
    case eitherMtime of
      Right mtime -> return mtime
      Left _ -> throwError $ PandocFileReadError fp


data PureState = PureState { stStdGen     :: StdGen
                           , stWord8Store :: [Word8] -- should be
                                                     -- inifinite,
                                                     -- i.e. [1..]
                           , stUniqStore  :: [Int] -- should be
                                                   -- inifinite and
                                                   -- contain every
                                                   -- element at most
                                                   -- once, e.g. [1..]
                           , envEnv :: [(String, String)]
                           , envTime :: UTCTime
                           , envTimeZone :: TimeZone
                           , envReferenceDocx :: Archive
                           , envReferenceODT :: Archive
                           , envFiles :: FileTree
                           , envUserDataDir :: FileTree
                           , envCabalDataDir :: FileTree
                           , envFontFiles :: [FilePath]   
                           }

instance Default PureState where
  def = PureState { stStdGen = mkStdGen 1848
                  , stWord8Store = [1..]
                  , stUniqStore = [1..]
                  , envEnv = [("USER", "pandoc-user")]
                  , envTime = posixSecondsToUTCTime 0
                  , envTimeZone = utc
                  , envReferenceDocx = emptyArchive
                  , envReferenceODT = emptyArchive
                  , envFiles = mempty
                  , envUserDataDir = mempty
                  , envCabalDataDir = mempty
                  , envFontFiles = []
                  }
data FileInfo = FileInfo { infoFileMTime :: UTCTime
                         , infoFileContents :: B.ByteString
                         }

newtype FileTree = FileTree {unFileTree :: M.Map FilePath FileInfo}
  deriving (Monoid)

getFileInfo :: FilePath -> FileTree -> Maybe FileInfo
getFileInfo fp tree = M.lookup fp $ unFileTree tree


newtype PandocPure a = PandocPure {
  unPandocPure :: ExceptT PandocError
                  (StateT CommonState (State PureState)) a
  } deriving ( Functor
             , Applicative
             , Monad
             , MonadState CommonState
             , MonadError PandocError
             )

runPure :: PandocPure a -> Either PandocError a
runPure x = flip evalState def $
            flip evalStateT def $
            runExceptT $
            unPandocPure x

instance PandocMonad PandocPure where
  lookupEnv s = PandocPure $ do
    env <- lift $ lift $ gets envEnv
    return (lookup s env)

  getCurrentTime = PandocPure $ lift $ lift $ gets envTime

  getCurrentTimeZone = PandocPure $ lift $ lift $ gets envTimeZone

  getDefaultReferenceDocx _ = PandocPure $ lift $ lift $ gets envReferenceDocx

  getDefaultReferenceODT _ = PandocPure $ lift $ lift $ gets envReferenceODT

  newStdGen = PandocPure $ do
    g <- lift $ lift $ gets stStdGen
    let (_, nxtGen) = next g
    lift $ lift $ modify $ \st -> st { stStdGen = nxtGen }
    return g

  newUniqueHash = PandocPure $ do
    uniqs <- lift $ lift $ gets stUniqStore
    case uniqs of
      u : us -> do
        lift $ lift $ modify $ \st -> st { stUniqStore = us }
        return u
      _ -> M.fail "uniq store ran out of elements"
  readFileLazy fp = PandocPure $ do
    fps <- lift $ lift $ gets envFiles
    case infoFileContents <$> getFileInfo fp fps of
      Just bs -> return (BL.fromStrict bs)
      Nothing -> throwError $ PandocFileReadError fp
  readDataFile Nothing "reference.docx" = do
    (B.concat . BL.toChunks . fromArchive) <$> (getDefaultReferenceDocx Nothing)
  readDataFile Nothing "reference.odt" = do
    (B.concat . BL.toChunks . fromArchive) <$> (getDefaultReferenceODT Nothing)
  readDataFile Nothing fname = do
    let fname' = if fname == "MANUAL.txt" then fname else "data" </> fname
    BL.toStrict <$> (readFileLazy fname')
  readDataFile (Just userDir) fname = PandocPure $ do
    userDirFiles <- lift $ lift $ gets envUserDataDir
    case infoFileContents <$> (getFileInfo (userDir </> fname) userDirFiles) of
      Just bs -> return bs
      Nothing -> unPandocPure $ readDataFile Nothing fname
  fail = M.fail
  fetchItem _ fp = PandocPure $ do
    fps <- lift $ lift $ gets envFiles
    case infoFileContents <$> (getFileInfo fp fps) of
      Just bs -> return (Right (bs, getMimeType fp))
      Nothing -> return (Left $ E.toException $ PandocFileReadError fp)

  fetchItem' media sourceUrl nm = do
    case MB.lookupMedia nm media of
      Nothing -> fetchItem sourceUrl nm
      Just (mime, bs) -> return (Right (B.concat $ BL.toChunks bs, Just mime))

  glob s = PandocPure $ do
    fontFiles <- lift $ lift $ gets envFontFiles
    return (filter (match (compile s)) fontFiles)

  getModificationTime fp = PandocPure $ do
    fps <- lift $ lift $ gets envFiles
    case infoFileMTime <$> (getFileInfo fp fps) of
      Just tm -> return tm
      Nothing -> throwError $ PandocFileReadError fp


    

    

    
