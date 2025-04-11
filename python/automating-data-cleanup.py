import csv

def clean_csv(file_path):
    with open(file_path, 'r') as infile:
        reader = csv.reader(infile)
        rows = [row for row in reader if any(row)]
    
    with open(file_path, 'w', newline='') as outfile:
        writer = csv.writer(outfile)
        writer.writerows(rows)
    
    print("Empty rows removed from CSV")

file = '/path/to/your/data.csv' clean_csv(file)
