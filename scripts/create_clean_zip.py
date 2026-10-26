import os
import zipfile

source_dir = r"D:\Semester 4\Project\Final Project\microlink"
output_zip = r"D:\Semester 4\Project\Final Project\MicroLink_Updated_System.zip"

exclude_dirs = {".dart_tool", "build", "__pycache__", ".git", ".gradle"}
exclude_extensions = {".pyc", ".lock"}

print(f"Creating zip archive: {output_zip} ...")
with zipfile.ZipFile(output_zip, "w", zipfile.ZIP_DEFLATED) as zipf:
    for root, dirs, files in os.walk(source_dir):
        dirs[:] = [d for d in dirs if d not in exclude_dirs]
        for file in files:
            if any(file.endswith(ext) for ext in exclude_extensions):
                continue
            full_path = os.path.join(root, file)
            rel_path = os.path.relpath(full_path, source_dir)
            zipf.write(full_path, rel_path)

size_mb = os.path.getsize(output_zip) / (1024 * 1024)
print(f"Successfully created: {output_zip} ({size_mb:.2f} MB)")
