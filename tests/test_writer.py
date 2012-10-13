from unittest import TestCase
from coldshot.coldshot import Writer
import tempfile, shutil

class TestWriter( TestCase ):
    def setUp( self ):
        self.test_dir = tempfile.mkdtemp( prefix = 'coldshot-test' )
        self.writer = Writer( self.test_dir, 1 )
        
    def tearDown( self ):
        self.writer.close()
        shutil.rmtree( self.test_dir, True )
    
    def assert_calls_written( self, *expected ):
        return self._base_was_written( self.writer.calls_filename, expected )
    def assert_lines_written( self, *expected ):
        return self._base_was_written( self.writer.lines_filename, expected )
    def assert_index_written( self, *expected ):
        return self._base_was_written( self.writer.index_filename, expected )
    
    def _base_was_written( self, filename, expected ):
        output = open( filename ).read()
        expected = ''.join( expected )
        output = output.decode( 'latin-1' )
        assert output == expected, (expected, output)
    def test_prefix( self ):
        self.writer.prefix( )
        self.writer.close()
        # TODO: make test 32-bit and big-endian friendly...
        self.assert_index_written( u'P COLDSHOTBinary v1 \x01\x00\x00\x00\x00\x00\x00\x00\n' )
    
    def test_file( self ):
        self.writer.file( 23, 'Boo hoo' )
        self.writer.close()
        self.assert_index_written( 'F 23 Boo%20hoo\n' )
    def test_func( self ):
        self.writer.func( 23, 25, 'funcname' )
        self.writer.close()
        self.assert_index_written( 'f 23 25 funcname\n' )
    def test_call( self ):
        self.writer.call( 2, 1, 1, 1 )
        self.writer.close()
        self.assert_calls_written( 'c\x02\x00\x00\x00\x01\x00\x01\x00\x01\x00\x00\x00\x00\x00\x00\x00' )
    def test_return( self ):
        self.writer.return_( 2, 1,2, 1 )
        self.writer.close()
        self.assert_calls_written( u'r\x02\x00\x00\x00\x01\x00\x02\x00\x01\x00\x00\x00\x00\x00\x00\x00' )
    def test_line( self ):
        self.writer.line( 2, 25, 1 )
        self.writer.close()
        self.assert_lines_written( u'\x02\x00\x00\x00\x00\x00\x19\x00\x01\x00\x00\x00\x00\x00\x00\x00' )
