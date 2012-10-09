from unittest import TestCase
from coldshot.coldshot import Profiler
import numpy

def blah():
    return True

class TestProfiler( TestCase ):
    TEST_FILE = '.test.profile'
    INDEX_FILE = TEST_FILE + '.index'
    def setUp( self ):
        self.profiler = Profiler( self.TEST_FILE )
    def test_create( self ):
        pass 
    def test_start( self ):
        self.profiler.start()
        blah()
        self.profiler.stop()
        filename = self.profiler.filename 
        content = open( filename ).read()
        # each record is 2 + 2 + 8 bytes
        assert content, content
        assert len(content)%12 == 0, content
        index = open( self.profiler.index_filename ).read()
        assert 'blah' in index, index
        
