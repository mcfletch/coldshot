import time, threading

def main():
    threads = []
    for i in range( 200 ):
        t = threading.Thread( target = sleeper )
        t.start()
        threads.append( t )
    for thread in threads:
        thread.join()

def sleeper():
    for i in range(20):
        time.sleep( 0.1 )

if __name__ == "__main__":
    main()
