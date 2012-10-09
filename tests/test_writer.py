from unittest import TestCase
from coldshot.coldshot import Writer,TestWrite

class TestWriter( TestCase ):
    def setUp( self ):
        self.output = []
        self.writer = Writer( self.output.append, 1 )
    def assert_was_written( self, *expected ):
        expected = list( expected )
        assert self.output == expected, (expected, self.output)
    def test_prefix( self ):
        self.writer.prefix( )
        self.assert_was_written( 'COLDSHOT ASCII v1\n' )
    def test_file( self ):
        self.writer.file( 23, 'Boo hoo' )
        self.assert_was_written( 'F 23 Boo%20hoo\n' )
    def test_func( self ):
        self.writer.func( 23, 25, 'funcname' )
        self.assert_was_written( 'f 23 25 funcname\n' )
    def test_call( self ):
        self.writer.call( 23, 25, 233344433344 )
        self.assert_was_written( 'C 23 25 233344433344\n' )
    def test_return( self ):
        self.writer.return_( 233344433388 )
        self.assert_was_written( 'R 233344433388\n' )
    def test_line( self ):
        self.writer.line( 25, 233344433390 )
        self.assert_was_written( 'L 233344433390\n' )
    def test_test_writer( self ):
        w = TestWrite( 'test.txt' )
        w.test_write( )
        w.close()
        content = open( 'test.txt' ).read()
        import struct
        print struct.unpack( '<Q', content )
    
