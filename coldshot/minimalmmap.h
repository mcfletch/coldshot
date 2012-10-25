/* Trivially declares the pieces of a mmap object we care about */
typedef struct {
    PyObject_HEAD
    void *      data;
} mmap_object;
