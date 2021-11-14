#!/bin/bash

# USAGE: script.sh output_name read_file [ read_file... ]
# 
# Description:
#
# Script that assembly and polish a genome from a set of read_files 
# General pipeline: flye --> racon --> medaka --> longstitch 
# Final assembly is output as ${output_name}.FINAL_ASSEMBLY.fa
# Busco and Quast is run after every step for quality control
# Singularity containers is used to run commands


mkdir -p logs
logfile=logs/`basename $0`"_"`date "+%Y-%m-%d_%H:%M:%S"`.log
exec >> $logfile 2>&1


NAME=${1}
shift
READS=$@

CONTAINER_DIR='/projects/CanSeq/containers'
BUSCO_DB='/projects/CanSeq/scratch/nanopore_q20/busco_lineage_dataset/euarchontoglires_odb10'
REF_GENOME='/projects/alignment_references/Homo_sapiens/hg38_no_alt/genome/fasta/hg38_no_alt.fa'

MEDAK_MODEL='r104_e81_sup_g5015'
RACON_REPEAT=1
THREAD=72

################## 
#CONCATANATE READS 
##################
cat ${READS} > ${NAME}.reads.fastq.gz

#########
#ASSEMBLY
#########

## FLYE (v2.9)
singularity exec -B /projects ${CONTAINER_DIR}/flye_3.9--py27h6a42192_0.sif flye --nano-hq ${NAME}.reads.fastq.gz --out-dir ${NAME}.flye_assembly --read-error 0.03 --threads ${THREAD}

################ 
#QUALITY CONTROL
################

## BUSCO (v5.2.2)
ulimit -u 100000
singularity exec -B /projects ${CONTAINER_DIR}/busco_5.2.2--pyhdfd78af_0.sif /usr/local/bin/busco -i ${NAME}.flye_assembly/assembly.fasta -m genome -o ${NAME}.busco_flye -l ${BUSCO_DB} -c ${THREAD}

## QUAST (v5.0.2)
singularity exec -B /projects ${CONTAINER_DIR}/quast_5.0.2--py37pl5262hfecc14a_5.sif /usr/local/bin/quast.py ${NAME}.flye_assembly/assembly.fasta -r ${REF_GENOME} -o ${NAME}.quast_flye -t ${THREAD}

##########
#POLISHING
##########
ASSEMBLY="${NAME}.flye_assembly/assembly.fasta"

for (( i = 1; i <= ${RACON_REPEAT}; i++ ))
do
	## MINIMAP2 (v2.22)
	singularity exec -B /projects ${CONTAINER_DIR}/minimap2_2.22--h5bf99c6_0.sif minimap2 -t ${THREAD} -xmap-ont ${ASSEMBLY} ${NAME}.reads.fastq.gz > ${NAME}.overlap${i}.paf 2>/dev/null
	## RACON (1.4.20)
	singularity exec -B /projects ${CONTAINER_DIR}/racon_1.4.20--h9a82719_1.sif racon -t ${THREAD} -m 8 -x -6 -g -8 -w 500 ${NAME}.reads.fastq.gz ${NAME}.overlap${i}.paf ${ASSEMBLY} > ${NAME}.assembly.racon_${i}.fastq 2> /dev/null
	
	ASSEMBLY="${NAME}.assembly.racon_${i}.fastq"

## MEDAKA (1.4.4)
singularity exec -B /projects ${CONTAINER_DIR}/medaka_1.4.4--py38h130def0_0.sif medaka_consensus -i ${NAME}.reads.fastq.gz -d ${ASSEMBLY} -o ${NAME}.medaka -t ${THREAD} -m ${MEDAK_MODEL}

## BUSCO (v5.2.2)
singularity exec -B /projects ${CONTAINER_DIR}/busco_5.2.2--pyhdfd78af_0.sif /usr/local/bin/busco -i ${NAME}.medaka/consensus.fasta -m genome -o ${NAME}.busco_racon_medaka -l ${BUSCO_DB} -c ${THREAD}

## QUAST (v5.0.2)
singularity exec -B /projects ${CONTAINER_DIR}/quast_5.0.2--py37pl5262hfecc14a_5.sif /usr/local/bin/quast.py ${NAME}.medaka/consensus.fasta -r ${REF_GENOME} -o ${NAME}.quast_racon_medaka -t ${THREAD}

###########
# STITCHING
###########

# Make longstich directory and symlink files into directory 
mkdir ${NAME}.longstich

ln -s ${NAME}.reads.fastq.gz ${NAME}.longstitch/${NAME}.reads.fq.gz
ln -s ${NAME}.medaka/consensus.fasta ${NAME}.longstitch/${NAME}.assembly.fa

cd ${NAME}.longstitch

## LONGSTITCH (v1.0.1)
singularity exec -B /projects ${CONTAINER_DIR}/longstitch_1.0.1--hdfd78af_1.sif longstitch tigmint-ntLink-arks draft=${NAME}.assembly.fa reads=q20.reads t=${THREAD} G=2e9 z=100

cd ..

ln -s ${NAME}.longstitch/${NAME}.assembly.k32.w100.tigmint-ntLink-arks.longstitch-scaffolds.fa ${NAME}.FINAL_ASSEMBLY.fa

## BUSCO (v5.2.2)
singularity exec -B /projects ${CONTAINER_DIR}/busco_5.2.2--pyhdfd78af_0.sif /usr/local/bin/busco -i ${NAME}.FINAL_ASSEMBLY.fa -m genome -o ${NAME}.busco_longstitch -l ${BUSCO_DB} -c ${THREAD}

## QUAST (v5.0.2)
singularity exec -B /projects ${CONTAINER_DIR}/quast_5.0.2--py37pl5262hfecc14a_5.sif /usr/local/bin/quast.py ${NAME}.FINAL_ASSEMBLY.fa -r ${REF_GENOME} -o ${NAME}.quast_longstitch -t ${THREAD}

