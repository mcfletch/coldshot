from unittest import TestCase
from coldshot.coldshot import Profiler
from coldshot.loader import Loader
import numpy, tempfile, os, shutil

def blah():
    return True

class TestProfiler( TestCase ):
    def setUp( self ):
        self.test_dir = tempfile.mkdtemp( prefix = 'coldshot-test' )
        self.profiler = Profiler( self.test_dir )
    def tearDown( self ):
        self.profiler.stop()
        shutil.rmtree( self.test_dir, True )
        
    def test_create( self ):
        pass 
    def test_start( self ):
        self.profiler.start()
        blah()
        self.profiler.stop()
        loader = Loader( self.test_dir )
        
        assert loader.files
        assert len(loader.files) == 1, loader.files 
        
        assert loader.functions 
        assert len(loader.functions) == 1, loader.functions
        fileno,lineno = loader.functions.keys()[0]
        
        records = loader.fcalls( fileno,lineno )
        assert len(records) == 1
        record = records[0] 
        assert record['fileno'] == fileno, (fileno,record)
        assert record['lineno'] == lineno, (fileno,record)

    
