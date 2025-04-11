import os

def bulk_rename(folder_path, old_name_part, new_name_part):
    for filename in os.listdir(folder_path):
        if old_name_part in filename:
            new_filename = filename.replace(old_name_part, new_name_part)
            os.rename(os.path.join(folder_path, filename), os.path.join(folder_path, new_filename))
            print(f"Renamed {filename} to {new_filename}")

folder = '/path/to/your/folder' bulk_rename(folder, 'old_part', 'new_part')
