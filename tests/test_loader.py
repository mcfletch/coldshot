from unittest import TestCase
from coldshot import profiler, loader 
import tempfile, os, shutil, time

def first_level():
    second_level()
    second_level()
def second_level():
    third_level()
    third_level()
def third_level():
    time.sleep( 0.001 )

def recurse( x ):
    if x <= 1:
        return x
    else:
        return recurse( x-1 ) + recurse( x-2 )
    
class TestProfiler( TestCase ):
    first_key = ('tests.test_loader','first_level')
    second_key = ('tests.test_loader','second_level')
    third_key = ('tests.test_loader','third_level')
    recurse_key = ('tests.test_loader','recurse')
    def setUp( self ):
        self.test_dir = tempfile.mkdtemp( prefix = 'coldshot-test' )
        self.profiler = profiler.Profiler( self.test_dir )
        self.profiler.start()
        recurse(10)
        first_level()
        self.profiler.stop()
        self.loader = loader.Loader( self.test_dir )
        self.loader.load()
    def tearDown( self ):
        shutil.rmtree( self.test_dir, True )
        
    def test_cumulative( self ):
        cumulative = self.loader.root.cumulative
        local = self.loader.root.local
        assert cumulative, self.loader.root.time
        assert local, self.loader.root.local
        assert abs( cumulative - 0.004 ) < .001, ("Expect a little more accuracy from time and profiler", cumulative)
        assert local < .001, "Expect less than 1ms for calling two functions"
    
    def test_has_functions( self ):
        for key in [self.first_key, self.second_key, self.third_key]:
            assert key in self.loader.function_names
    
    def test_parents( self ):
        func = self.loader.function_names[ self.recurse_key ]
        parents = func.parents 
        assert func in parents, parents

    def test_root_children( self ):
        root = self.loader.function_names[ ('*','*') ]
        assert len( root.children ) == 2, root.children
    
