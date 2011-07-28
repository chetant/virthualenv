module Actions ( cabalUpdate
               , installCabalConfig
               , installCabalWrapper
               , installActivateScript
               , copyBaseSystem
               , initGhcDb
               , installGhc
               , createDirStructure
               ) where

import System.Directory (setCurrentDirectory, getCurrentDirectory, createDirectory, removeDirectoryRecursive)
import Control.Monad.Trans (liftIO)
import Control.Monad.Reader (asks)
import Control.Monad.Error (throwError)
import System.FilePath ((</>))
import Distribution.Version (Version (..))
import Distribution.Package (PackageName(..))
import Safe (lastMay)

import MyMonad
import Types
import Paths
import PackageManagement
import Process
import Util.Template (substs)
import Util.IO (makeExecutable, createTemporaryDirectory)
import Skeletons

-- update cabal package info inside Virtual Haskell Environmentn
cabalUpdate :: MyMonad ()
cabalUpdate = do
  env         <- getVirtualEnvironment
  cabalConfig <- cabalConfigLocation
  info "Updating cabal package database inside Virtual Haskell Environment."
  _ <- indentMessages $ runProcess (Just env) "cabal" ["--config-file=" ++ cabalConfig, "update"] Nothing
  return ()

-- install cabal wrapper (in bin/ directory) inside virtual environment dir structure
installCabalWrapper :: MyMonad ()
installCabalWrapper = do
  cabalConfig      <- cabalConfigLocation
  dirStructure     <- vheDirStructure
  let cabalWrapper = virthualEnvBinDir dirStructure </> "cabal"
  info $ concat [ "Installing cabal wrapper using "
                , cabalConfig
                , " at "
                , cabalWrapper
                ]
  let cabalWrapperContents = substs [("<CABAL_CONFIG>", cabalConfig)] cabalWrapperSkel
  indentMessages $ do
    trace "cabal wrapper contents:"
    mapM_ trace $ lines cabalWrapperContents
  liftIO $ writeFile cabalWrapper cabalWrapperContents
  liftIO $ makeExecutable cabalWrapper

-- install cabal wrapper (in bin/ directory) inside virtual environment dir structure
installActivateScript :: MyMonad ()
installActivateScript = do
  virthualEnvName <- asks vheName
  dirStructure    <- vheDirStructure
  ghc             <- asks ghcSource
  ghcPkgPath <- case ghc of
                 System    -> return $ ghcPackagePath dirStructure
                 Tarball _ -> do
                   externalGhcPkgDbPath <- indentMessages externalGhcPkgDb
                   return $ ghcPackagePath dirStructure ++ ":" ++ externalGhcPkgDbPath
  let activateScript = virthualEnvBinDir dirStructure </> "activate"
  info $ "Installing activate script at " ++ activateScript
  let activateScriptContents = substs [ ("<VIRTHUALENV_NAME>", virthualEnvName)
                                      , ("<VIRTHUALENV>", virthualEnv dirStructure)
                                      , ("<GHC_PACKAGE_PATH>", ghcPkgPath)
                                      , ("<VIRTHUALENV_BIN_DIR>", virthualEnvBinDir dirStructure)
                                      , ("<CABAL_BIN_DIR>", cabalBinDir dirStructure)
                                      , ("<GHC_BIN_DIR>", ghcBinDir dirStructure)
                                      ] activateSkel
  indentMessages $ do
    trace "activate script contents:"
    mapM_ trace $ lines activateScriptContents
  liftIO $ writeFile activateScript activateScriptContents

installCabalConfig :: MyMonad ()
installCabalConfig = do
  cabalConfig     <- cabalConfigLocation
  dirStructure    <- vheDirStructure
  liftIO $ putStrLn $ "Installing cabal config at " ++ cabalConfig
  let cabalConfigContents = substs [ ("<GHC_PACKAGE_PATH>", ghcPackagePath dirStructure)
                                   , ("<CABAL_DIR>", cabalDir dirStructure)
                                   ] cabalConfigSkel
  liftIO $ writeFile cabalConfig cabalConfigContents

createDirStructure :: MyMonad ()
createDirStructure = do
  dirStructure <- vheDirStructure
  info "Creating Virtual Haskell directory structure"
  indentMessages $ do
    debug $ "virthualenv directory: " ++ virthualEnvDir dirStructure
    liftIO $ createDirectory $ virthualEnvDir dirStructure
    debug $ "cabal directory: " ++ cabalDir dirStructure
    liftIO $ createDirectory $ cabalDir dirStructure
    debug $ "virthualenv bin directory: " ++ virthualEnvBinDir dirStructure
    liftIO $ createDirectory $ virthualEnvBinDir dirStructure

initGhcDb :: MyMonad ()
initGhcDb = do
  dirStructure <- vheDirStructure
  info $ "Initializing GHC Package database at " ++ ghcPackagePath dirStructure
  out <- indentMessages $ outsideGhcPkg ["--version"]
  case lastMay $ words out of
    Nothing            -> throwError $ MyException $ "Couldn't extract ghc-pkg version number from: " ++ out
    Just versionString -> do
      indentMessages $ trace $ "Found version string: " ++ versionString
      version <- parseVersion versionString
      let ghc_6_12_1_version = Version [6,12,1] []
      if version < ghc_6_12_1_version then do
        indentMessages $ debug "Detected GHC older than 6.12, initializing GHC_PACKAGE_PATH to file with '[]'"
        liftIO $ writeFile (ghcPackagePath dirStructure) "[]"
       else do
        _ <- indentMessages $ outsideGhcPkg ["init", ghcPackagePath dirStructure]
        return ()

copyBaseSystem :: MyMonad ()
copyBaseSystem = do
  info "Copying necessary packages from original GHC package database"
  indentMessages $ do
    ghc <- asks ghcSource
    case ghc of
      System -> do
        transplantPackage $ PackageName "base"
        transplantPackage $ PackageName "Cabal"
        transplantPackage $ PackageName "haskell98"
        transplantPackage $ PackageName "haskell2010"
        transplantPackage $ PackageName "ghc"
        transplantPackage $ PackageName "ghc-binary"
      Tarball _ ->
        debug "Using external GHC - nothing to copy, Virtual environment will reuse GHC package database"

installGhc :: MyMonad ()
installGhc = do
  info "Installing GHC"
  ghc <- asks ghcSource
  case ghc of
    System              -> indentMessages $ debug "Using system version of GHC - nothing to install."
    Tarball tarballPath -> indentMessages $ installExternalGhc tarballPath

installExternalGhc :: FilePath -> MyMonad ()
installExternalGhc tarballPath = do
  info $ "Installing GHC from " ++ tarballPath
  dirStructure <- vheDirStructure
  tmpGhcDir <- liftIO $ createTemporaryDirectory (virthualEnv dirStructure) "ghc"
  indentMessages $ debug $ "Unpacking GHC tarball to " ++ tmpGhcDir
  _ <- indentMessages $ runProcess Nothing "tar" ["xf", tarballPath, "-C", tmpGhcDir, "--strip-components", "1"] Nothing
  let configureScript = tmpGhcDir </> "configure"
  indentMessages $ debug $ "Configuring GHC with prefix " ++ ghcDir dirStructure
  cwd <- liftIO getCurrentDirectory
  liftIO $ setCurrentDirectory tmpGhcDir
  _ <- indentMessages $ runProcess Nothing configureScript ["--prefix=" ++ ghcDir dirStructure] Nothing
  make <- asks makeCmd
  indentMessages $ debug $ "Installing GHC with " ++ make ++ " install"
  _ <- runProcess Nothing make ["install"] Nothing
  liftIO $ setCurrentDirectory cwd
  liftIO $ removeDirectoryRecursive tmpGhcDir
  return ()
