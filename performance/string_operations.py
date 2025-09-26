import random

def main():
    random.seed(42)
    result = ""
    count = 0

    # String operations benchmark
    for i in range(5000):
        num = random.randint(0, 1000)
        str_num = str(num)

        # String concatenation
        result = result + str_num + ","

        # String length operations
        count = count + len(result)

        # Reset result periodically to avoid excessive memory usage
        if i % 100 == 0:
            result = str_num

    print(count)
    print(len(result))

main()