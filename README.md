# Genome Aseembly Pipeline
A simple genome assembly pipeline written during rotations in the Jones Lab at UBC.

Pipeline was used to assembly reads from q20 nanopore dataset into a genome. 
The general pipeline consist of this:
Flye --> Racon --> Medaka --> LongStitch

Flye is used as the initial genome assembly. Racon and Medaka is used for polishing. LongStitch is used for genome correction and scaffolding. 
After each step, Busco and Quast is used to determine 
