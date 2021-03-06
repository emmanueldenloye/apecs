{-# LANGUAGE Strict #-}
{-# LANGUAGE ScopedTypeVariables, RankNTypes #-}
{-# LANGUAGE TypeFamilies, TypeFamilyDependencies #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleContexts, FlexibleInstances #-}
{-# LANGUAGE ConstraintKinds, KindSignatures #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module Apecs.Core where

import Control.Monad.Reader
import Data.Traversable (for)
import qualified Data.Vector.Unboxed as U

-- | A component is defined by the type of its storage
--   The storage in turn supplies runtime types for the component.
class Initializable (Storage c) => Component c where
  type Storage c = s | s -> c

type ID    = Int
type IDVec = U.Vector ID
newtype System w a = System {unSystem :: ReaderT w IO a} deriving (Functor, Monad, Applicative, MonadIO)
newtype Slice  c = Slice  {unSlice  :: U.Vector ID} deriving (Show, Monoid)
newtype Entity c = Entity {unEntity :: ID} deriving (Eq, Num)

{-# INLINE runSystem #-}
runSystem :: System w a -> w -> IO a
runSystem sys = runReaderT (unSystem sys)

{-# INLINE runWith #-}
runWith :: w -> System w a -> IO a
runWith = flip runSystem

-- Storage type class hierarchy
-- | Common for every storage. Represents a container that can be initialized
class Initializable s where
  type InitArgs s
  initStoreWith :: InitArgs s -> IO s

-- | A store that is indexed by entities
class HasMembers s where
  explDestroy :: s -> Int -> IO ()
  explExists  :: s -> Int -> IO Bool
  explMembers :: s -> IO (U.Vector Int)

  {-# INLINE explReset #-}
  explReset :: s -> IO ()
  explReset s = do
    sl <- explMembers s
    U.mapM_ (explDestroy s) sl

  explImapM_ :: MonadIO m => s -> (Int -> m a) -> m ()
  {-# INLINE explImapM_ #-}
  explImapM_ s ma = liftIO (explMembers s) >>= Prelude.mapM_ ma . U.toList

  explImapM :: MonadIO m => s -> (Int -> m a) -> m [a]
  {-# INLINE explImapM #-}
  explImapM s ma = liftIO (explMembers s) >>= Prelude.mapM ma . U.toList

{-# INLINE imapM_ #-}
-- | Monadically iterate a system over all entities that have that component.
--   Note that writing to the store while iterating over it is undefined behaviour.
imapM_ :: forall w c. (Has w c, HasMembers (Storage c))
       => (Entity c -> System w ()) -> System w ()
imapM_ sys = do s :: Storage c <- getStore
                explImapM_ s (sys . Entity)

{-# INLINE imapM #-}
-- | Monadically iterate a system over all entities that have that component.
--   Note that writing to the store while iterating over it is undefined behaviour.
imapM :: forall w c a. (Has w c, HasMembers (Storage c))
      => (Entity c -> System w a) -> System w [a]
imapM sys = do s :: Storage c <- getStore
               explImapM s (sys . Entity)

-- | Destroys the component @c@ for the given entity
{-# INLINE destroy #-}
destroy :: forall w c. (Has w c, HasMembers (Storage c)) => Entity c -> System w ()
destroy (Entity n) = do s :: Storage c <- getStore
                        liftIO$ explDestroy s n

-- | Returns whether the given entity has component @c@
--   For composite components, this indicates whether the component
--   has all its constituents
{-# INLINE exists #-}
exists :: forall w c. (Has w c, HasMembers (Storage c)) => Entity c -> System w Bool
exists (Entity n) = do s :: Storage c <- getStore
                       liftIO$ explExists s n

-- | A slice containing all entities with component @c@
{-# INLINE owners #-}
owners :: forall w c. (Has w c, HasMembers (Storage c)) => System w (Slice c)
owners = do s :: Storage c <- getStore
            liftIO$ Slice <$> explMembers s

resetStore :: forall w c p. (Has w c, HasMembers (Storage c)) => p c -> System w ()
resetStore _ = do s :: Storage c <- getStore
                  liftIO$ explReset s

-- | Class of storages that associates components with entities.
class HasMembers s => Store s where
  type SafeRW s -- ^ Return type for safe reads/writes to the store
  type Stores s -- ^ The type of components stored by this Store
  -- | Unsafe index to the store. Undefined if the component does not exist
  explGetUnsafe :: s -> Int -> IO (Stores s)
  -- | Retrieves a component from the store
  explGet       :: s -> Int -> IO (SafeRW s)
  -- | Writes a component
  explSet       :: s -> Int -> Stores s -> IO ()
  -- | Either writes or deletes a component
  explSetMaybe  :: s -> Int -> SafeRW s -> IO ()

  -- | Modifies an element in the store.
  {-# INLINE explModify #-}
  explModify :: s -> Int -> (Stores s -> Stores s) -> IO ()
  explModify s ety f = do etyExists <- explExists s ety
                          when etyExists $ explGetUnsafe s ety >>= explSet s ety . f

  -- | Maps over all elements of this store.
  --   The default implementation can be replaced by an optimized one
  explCmap :: s -> (Stores s -> Stores s) -> IO ()
  {-# INLINE explCmap #-}
  explCmap s f = do
    sl <- explMembers s
    U.forM_ sl $ \ety -> do
      x :: Stores s <- explGetUnsafe s ety
      explSet s ety (f x)

  explCmapM_ :: MonadIO m => s -> (Stores s -> m a) -> m ()
  {-# INLINE explCmapM_ #-}
  explCmapM_ s sys = do
    sl <- liftIO$ explMembers s
    U.forM_ sl $ \ety -> do x :: Stores s <- liftIO$ explGetUnsafe s ety
                            sys x

  explCimapM_ :: MonadIO m => s -> ((Int, Stores s) -> m a) -> m ()
  {-# INLINE explCimapM_ #-}
  explCimapM_ s sys = do
    sl <- liftIO$ explMembers s
    U.forM_ sl $ \ety -> do x :: Stores s <- liftIO$ explGetUnsafe s ety
                            sys (ety,x)

  explCmapM  :: MonadIO m => s -> (Stores s -> m a) -> m [a]
  {-# INLINE explCmapM #-}
  explCmapM s sys = do
    sl <- liftIO$ explMembers s
    for (U.toList sl) $ \ety -> do
      x :: Stores s <- liftIO$ explGetUnsafe s ety
      sys x

  explCimapM :: MonadIO m => s -> ((Int, Stores s) -> m a) -> m [a]
  {-# INLINE explCimapM #-}
  explCimapM s sys = do
    sl <- liftIO$ explMembers s
    for (U.toList sl) $ \ety -> do
      x :: Stores s <- liftIO$ explGetUnsafe s ety
      sys (ety,x)

-- | A constraint that indicates that the runtime representation of @c@ is @c@
type Runtime c = Stores (Storage c)
type IsRuntime c = (Store (Storage c), Runtime c ~ c)
newtype Safe c = Safe {getSafe :: (SafeRW (Storage c))}

-- Setting/Getting
{-# INLINE get #-}
get :: forall w c. (Store (Storage c), Has w c) => Entity c -> System w (Safe c)
get (Entity ety) = do s :: Storage c <- getStore
                      liftIO$ Safe <$> explGet s ety

{-# INLINE set #-}
set :: forall w c e. (Store (Storage c), Stores (Storage c) ~ c, Has w c) => Entity e -> c -> System w ()
set (Entity ety) x = do
  s :: Storage c <- getStore
  liftIO$ explSet s ety x

{-# INLINE modify #-}
modify :: forall w c. (IsRuntime c, Has w c) => Entity c -> (c -> c) -> System w ()
modify (Entity ety) f = do
  s :: Storage c <- getStore
  liftIO$ explModify s ety f

setMaybe :: forall w c. (IsRuntime c, Has w c) => Entity c -> Safe c -> System w ()
setMaybe (Entity ety) (Safe c) = do
  s :: Storage c <- getStore
  liftIO$ explSetMaybe s ety c

{-# INLINE cmap #-}
cmap :: forall world c. (IsRuntime c, Has world c) => (c -> c) -> System world ()
cmap f = do s :: Storage c <- getStore
            liftIO$ explCmap s f

{-# INLINE cmapM_ #-}
cmapM_ :: forall w c. (Has w c, IsRuntime c)
       => (c -> System w ()) -> System w ()
cmapM_ sys = do s :: Storage c <- getStore
                explCmapM_ s sys

{-# INLINE cimapM_ #-}
cimapM_ :: forall w c. (Has w c, IsRuntime c)
        => ((Entity c, c) -> System w ()) -> System w ()
cimapM_ sys = do s :: Storage c <- getStore
                 explCimapM_ s (\(e,c) -> sys (Entity e,c))

{-# INLINE cmapM #-}
cmapM :: forall w c a. (Has w c, IsRuntime c)
      => (c -> System w a) -> System w [a]
cmapM sys = do s :: Storage c <- getStore
               explCmapM s sys

{-# INLINE cimapM #-}
cimapM :: forall w c a. (Has w c, IsRuntime c)
       => ((Entity c, c) -> System w a) -> System w [a]
cimapM sys = do s :: Storage c <- getStore
                explCimapM s (\(e,c) -> sys (Entity e,c))

-- | Class of storages for global values
class GlobalRW s c where
  {-# MINIMAL explGlobalRead, explGlobalWrite #-}
  explGlobalRead :: s -> IO c
  explGlobalWrite :: s -> c -> IO ()

  {-# INLINE explGlobalModify #-}
  explGlobalModify :: s -> (c -> c) -> IO ()
  explGlobalModify s f = do r <- explGlobalRead s
                            explGlobalWrite s (f r)

{-# INLINE readGlobal #-}
readGlobal :: forall w c. (Has w c, GlobalRW (Storage c) c) => System w c
readGlobal = do s :: Storage c <- getStore
                liftIO$ explGlobalRead s

{-# INLINE writeGlobal #-}
writeGlobal :: forall w c. (Has w c, GlobalRW (Storage c) c) => c -> System w ()
writeGlobal c = do s :: Storage c <- getStore
                   liftIO$ explGlobalWrite s c

{-# INLINE modifyGlobal #-}
modifyGlobal :: forall w c. (Has w c, GlobalRW (Storage c) c) => (c -> c) -> System w ()
modifyGlobal f = do s :: Storage c <- getStore
                    liftIO$ explGlobalModify s f

-- Query
class Query q s where
  explSlice :: s -> q -> IO (U.Vector Int)

{-# INLINE slice #-}
slice :: forall w c q. (Query q (Storage c), Has w c) => q -> System w (Slice c)
slice q = do
  s :: Storage c <- getStore
  liftIO$ Slice <$> explSlice s q

data All = All
instance HasMembers s => Query All s where
  {-# INLINE explSlice #-}
  explSlice s _ = explMembers s

class Cast a b where cast :: a -> b
instance Cast (Entity a) (Entity b) where
  {-# INLINE cast #-}
  cast (Entity ety) = Entity ety
instance Cast (Slice a) (Slice b) where
  {-# INLINE cast #-}
  cast (Slice vec) = Slice vec

class Component c => Has w c where
  getStore :: System w (Storage c)

instance Show (Entity c) where
  show (Entity e) = "Entity " ++ show e

{-# INLINE sliceFoldM_ #-}
sliceFoldM_ :: (a -> Entity c -> System w a) -> a -> Slice b -> System w ()
sliceFoldM_ f seed (Slice sl) = U.foldM'_ ((.Entity) . f) seed sl

-- | Gets the size of a slice (O(n))
{-# INLINE sliceSize #-}
sliceSize :: Slice a -> Int
sliceSize (Slice vec) = U.length vec

-- | Tests whether a slice is empty (O(1))
{-# INLINE sliceNull #-}
sliceNull :: Slice a -> Bool
sliceNull (Slice vec) = U.null vec

-- | Construct a slice from a list of IDs
{-# INLINE sliceFromList #-}
sliceFromList :: [ID] -> Slice a
sliceFromList = Slice . U.fromList

-- | Monadically filter a slice
{-# INLINE sliceFilterM #-}
sliceFilterM :: (Entity c -> System w Bool) -> Slice c -> System w (Slice c)
sliceFilterM fm (Slice vec) = Slice <$> U.filterM (fm . Entity) vec

{-# INLINE sliceConcat #-}
sliceConcat :: Slice a -> Slice b -> Slice c
sliceConcat (Slice a) (Slice b) = Slice (a U.++ b)


-- Tuple instances
-- (,)
instance (Component a, Component b) => Component (a,b) where
  type Storage (a, b) = (Storage a, Storage b)
instance (Has w a, Has w b) => Has w (a,b) where
  {-# INLINE getStore #-}
  getStore = (,) <$> getStore <*> getStore

instance (Initializable a, Initializable b) => Initializable (a,b) where
  type InitArgs (a, b) = (InitArgs a, InitArgs b)
  initStoreWith (aa, ab) = (,) <$> initStoreWith aa <*> initStoreWith ab

instance (HasMembers a, HasMembers b) => HasMembers (a,b) where
  explMembers (sa,sb) = explMembers sa >>= U.filterM (explExists sb)
  explReset   (sa,sb) = explReset sa >> explReset sb
  explDestroy (sa,sb) ety = explDestroy sa ety >> explDestroy sb ety
  explExists  (sa,sb) ety = (&&) <$> explExists sa ety <*> explExists sb ety
  {-# INLINE explMembers #-}
  {-# INLINE explReset #-}
  {-# INLINE explDestroy #-}
  {-# INLINE explExists #-}

instance (Store a, Store b) => Store (a, b) where
  type SafeRW (a, b) = (SafeRW a, SafeRW b)
  type Stores (a, b) = (Stores a, Stores b)
  explGetUnsafe  (sa,sb) ety = (,) <$> explGetUnsafe sa ety <*> explGetUnsafe sb ety
  explGet        (sa,sb) ety = (,) <$> explGet sa ety <*> explGet sb ety
  explSet        (sa,sb) ety (wa,wb) = explSet sa ety wa >> explSet sb ety wb
  explSetMaybe   (sa,sb) ety (wa,wb) = explSetMaybe sa ety wa >> explSetMaybe sb ety wb
  {-# INLINE explGetUnsafe #-}
  {-# INLINE explGet #-}
  {-# INLINE explSet #-}
  {-# INLINE explSetMaybe #-}

instance (GlobalRW a ca, GlobalRW b cb) => GlobalRW (a,b) (ca,cb) where
  explGlobalRead  (sa,sb) = (,) <$> explGlobalRead sa <*> explGlobalRead sb
  explGlobalWrite (sa,sb) (wa,wb) = explGlobalWrite sa wa >> explGlobalWrite sb wb
  {-# INLINE explGlobalRead #-}
  {-# INLINE explGlobalWrite #-}

-- (,,)
instance (Component a, Component b, Component c) => Component (a,b,c) where
  type Storage (a, b, c) = (Storage a, Storage b, Storage c)
instance (Has w a, Has w b, Has w c) => Has w (a,b,c) where
  {-# INLINE getStore #-}
  getStore = (,,) <$> getStore <*> getStore <*> getStore

instance (Initializable a, Initializable b, Initializable c) => Initializable (a,b,c) where
  type InitArgs (a, b, c) = (InitArgs a, InitArgs b, InitArgs c)
  initStoreWith (aa, ab, ac) = (,,) <$> initStoreWith aa <*> initStoreWith ab <*> initStoreWith ac

instance (HasMembers a, HasMembers b, HasMembers c) => HasMembers (a,b,c) where
  explMembers (sa,sb,sc) = explMembers sa >>= U.filterM (explExists sb) >>= U.filterM (explExists sc)
  explReset   (sa,sb,sc) = explReset sa >> explReset sb >> explReset sc
  explDestroy (sa,sb,sc) ety = explDestroy sa ety >> explDestroy sb ety >> explDestroy sc ety
  explExists  (sa,sb,sc) ety = and <$> sequence [explExists sa ety, explExists sb ety, explExists sc ety]
  {-# INLINE explMembers #-}
  {-# INLINE explReset #-}
  {-# INLINE explDestroy #-}
  {-# INLINE explExists #-}

instance (Store a, Store b, Store c) => Store (a, b, c) where
  type SafeRW (a, b, c) = (SafeRW a, SafeRW b, SafeRW c)
  type Stores (a, b, c) = (Stores a, Stores b, Stores c)
  explGetUnsafe  (sa,sb,sc) ety = (,,) <$> explGetUnsafe sa ety <*> explGetUnsafe sb ety <*> explGetUnsafe sc ety
  explGet        (sa,sb,sc) ety = (,,) <$> explGet sa ety <*> explGet sb ety <*> explGet sc ety
  explSet        (sa,sb,sc) ety (wa,wb,wc) = explSet sa ety wa >> explSet sb ety wb >> explSet sc ety wc
  explSetMaybe   (sa,sb,sc) ety (wa,wb,wc) = explSetMaybe sa ety wa >> explSetMaybe sb ety wb >> explSetMaybe sc ety wc
  {-# INLINE explGetUnsafe #-}
  {-# INLINE explGet #-}
  {-# INLINE explSet #-}
  {-# INLINE explSetMaybe #-}

instance (GlobalRW a ca, GlobalRW b cb, GlobalRW c cc) => GlobalRW (a,b,c) (ca,cb,cc) where
  explGlobalRead  (sa,sb,sc) = (,,) <$> explGlobalRead sa <*> explGlobalRead sb <*> explGlobalRead sc
  explGlobalWrite (sa,sb,sc) (wa,wb,wc) = explGlobalWrite sa wa >> explGlobalWrite sb wb >> explGlobalWrite sc wc
  {-# INLINE explGlobalRead #-}
  {-# INLINE explGlobalWrite #-}
