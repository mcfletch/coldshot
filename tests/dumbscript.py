import time, threading

def main():
    threads = []
    print 'Starting'
    for i in range( 200 ):
        t = threading.Thread( target = lambda: sleeper() )
        t.start()
        threads.append( t )
    for thread in threads:
        thread.join()
    print 'Finished'

def sleeper():
    for i in range(20):
        time.sleep( 0.1 )

if __name__ == "__main__":
    main()
