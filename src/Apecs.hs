{-# LANGUAGE FlexibleContexts #-}

module Apecs (
  -- Core
    System(..), runSystem, runWith,
    Component(..), Entity, Slice, Has(..), Safe(..), cast,

    -- Initializable
    initStoreWith,

    -- HasMembers
    destroy, exists, owners, resetStore,

    -- Store
    get, set, setMaybe, modify,
    cmap, cmapM, cmapM_, cimapM, cimapM_,
    sliceSize,

    -- GlobalRW
    readGlobal, writeGlobal, modifyGlobal,

    -- Query
    slice, All(..),

  -- Reader
  asks, ask, liftIO, lift,
) where

import Apecs.Core as A
import Control.Monad.Reader (asks, ask, liftIO, lift)
