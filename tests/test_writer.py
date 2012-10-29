from unittest import TestCase
from coldshot import profiler, loader
import tempfile, shutil, os

class TestWriter( TestCase ):
    def setUp( self ):
        self.test_dir = tempfile.mkdtemp( prefix = 'coldshot-test' )
        
    def tearDown( self ):
        shutil.rmtree( self.test_dir, True )
    
    def test_calls_writer( self ):
        """Test that calls writer can write records as expected"""
        datafile = os.path.join( self.test_dir, 'test_calls_writer' )
        cw = profiler.DataWriter( datafile )
        cw.write( 8, 12, 14, 23, 2<<24 )
        cw.close()
        content = open( datafile,'rb' ).read()
        assert chr(8) in content, content 
        assert chr(12) in content, content 
        assert chr( 14 ) in content, content 
        assert chr( 23 ) in content, content 
        assert chr( 2 ) in content, content 
        assert len(content) == profiler.CALL_INFO_SIZE, content 

    def test_index_writer( self ):
        datafile = os.path.join( self.test_dir, 'test_index_writer' )
        iw = profiler.IndexWriter( datafile )
        iw.prefix( version=3 )
        iw.close()
        content = open( datafile,'rb' ).read()
        split = content.split()
        assert split[0] == 'P'
        assert split[2] == 'v3'
        assert split[3] == 'byteswap=False', """Coldshot has not yet been tested on big-endian platforms"""
