"""You can load a profile with the following:

    mm = numpy.memmap( '.test.profile' )
    mm.view([('fileno','<i2'),('lineno','<i2'),('timestamp','<L')])

"""
__version__ = '1.0.0a1'
from .coldshot import *
#from .loader import *
