from unittest import TestCase
from coldshot import profiler, loader 
import numpy, tempfile, os, shutil

def blah():
    return True

class TestProfiler( TestCase ):
    def setUp( self ):
        self.test_dir = tempfile.mkdtemp( prefix = 'coldshot-test' )
        self.profiler = profiler.Profiler( self.test_dir )
    def tearDown( self ):
        self.profiler.stop()
        shutil.rmtree( self.test_dir, True )
        
    def test_create( self ):
        pass 
    def test_start( self ):
        self.profiler.start()
        blah()
        self.profiler.stop()
        load = loader.Loader( self.test_dir )
        load.load()
        assert load.files
        assert len(load.files) == 1, load.files 
        
        assert load.functions 
        assert len(load.functions) == 2, load.functions # expected blah() and stop()
        for funcno, funcinfo in load.functions.items():
            assert funcinfo.name 
            assert funcinfo.calls

    def test_c_calls( self ):
        x = []
        self.profiler.start()
        for i in range(200):
            x.append( i )
        self.profiler.stop()
        assert self.profiler.files
        assert self.profiler.functions
        
        load = loader.Loader( self.test_dir )
        load.load()
        assert load.functions 
        assert len(load.functions) == 2, load.functions 
    
