import random

def create_array(size):
    arr = []
    for i in range(size):
        arr.append(i)
    return arr

def main():
    random.seed(42)
    total_length = 0

    # Memory allocation and array creation benchmark
    for i in range(1000):
        size = random.randint(10, 50)
        arr = create_array(size)

        total_length = total_length + len(arr)

        # Create some temporary arrays
        temp1 = [1, 2, 3, 4, 5]
        temp2 = temp1 + arr[0:5]
        total_length = total_length + len(temp2)

    print(total_length)

main()