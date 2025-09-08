# from archivist_os_all_versions import *

# v7 stress test (human resolves)
v7 = ArchivistOS_v7()
print(v7.stress_test())
print(v7.evaluate("hybrid"))

# v9 forks & compete
v9 = ArchivistOS_v9()
forks = v9.fork(3)
results, winner = v9.compete()
print(results, winner)

# v10 federation over v9 forks
v10 = ArchivistOS_v10(forks)
print(v10.federate(top_k=5))

# v20 living constitution mutating
v20 = ArchivistOS_v20()
for _ in range(3):
    print(v20.mutate(), "→", v20.express())
