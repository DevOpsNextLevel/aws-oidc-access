import pandas as pd

# Load the Excel file
df = pd.read_excel("AWS CLOUD ACCESS SPREADSHEET.xlsx", engine="openpyxl")

# Save it as CSV
df.to_csv("students.csv", index=False)

