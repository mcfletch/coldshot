from unittest import TestCase
from coldshot.coldshot import Writer

class TestWriter( TestCase ):
    TEST_FILE = '.test.profile'
    INDEX_FILE = TEST_FILE + '.index'
    def setUp( self ):
        self.writer = Writer( self.TEST_FILE, 1 )
    def assert_was_written( self, *expected ):
        return self._base_was_written( self.TEST_FILE, expected )
    def assert_index_written( self, *expected ):
        return self._base_was_written( self.INDEX_FILE, expected )
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
        self.writer.call( 1, 1, 1 )
        self.writer.close()
        self.assert_was_written( 'c\x01\x00\x01\x00\x01\x00\x00\x00\x00\x00\x00\x00' )
    def test_return( self ):
        self.writer.return_( 1,2, 1 )
        self.writer.close()
        self.assert_was_written( u'r\x01\x00\x02\x00\x01\x00\x00\x00\x00\x00\x00\x00' )
    def test_line( self ):
        self.writer.line( 25, 1 )
        self.writer.close()
        self.assert_was_written( u'l\x00\x00\x19\x00\x01\x00\x00\x00\x00\x00\x00\x00' )
