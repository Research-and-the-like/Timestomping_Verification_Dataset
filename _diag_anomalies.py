import pandas as pd
df = pd.read_csv(r"C:\Research\Data\Parsed\analysis_dataset.csv", low_memory=False)
positives = df[df['GroundTruth_Timestomped'] == 1].copy()
positives['Tool'] = positives['FileName'].str.extract(r'target_(T\d_[A-Za-z]+)_S\d')
positives['Scenario'] = positives['FileName'].str.extract(r'(S\d_[A-Za-z]+)')

print("=== T3 SetMace: files missed by Method B ===")
t3 = positives[positives['Tool'] == 'T3_SetMace']
t3_missed = t3[~t3['MethodB_Flagged']]
cols_b = ['FileName','Scenario','B1_Close_No_Create','B2_BasicInfoChange','B3_Timestamp_Gap','si_created','si_modified']
print(t3_missed[cols_b].to_string(index=False))
print("\nScenario breakdown of T3 misses:")
print(t3_missed['Scenario'].value_counts())

print("\n=== T5 nTimestomp: files missed by Method A ===")
t5 = positives[positives['Tool'] == 'T5_nTimestomp']
t5_missed = t5[~t5['MethodA_Flagged']]
cols_a = ['FileName','Scenario','A1_SI_Created_LT_FN','A2_SI_Mod_LT_SI_Created',
          'A3_SI_Entry_LT_SI_Created','A4_ZeroSubSec_si_created','A4_ZeroSubSec_si_modified',
          'A5_All_SI_Identical','si_created','fn_created','si_modified']
print(t5_missed[cols_a].to_string(index=False))
print("\nScenario breakdown of T5 misses:")
print(t5_missed['Scenario'].value_counts())