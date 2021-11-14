#!/bin/bash

# USAGE: script.sh [OPTIONS] output_name read_file [ read_file... ]
#
# Options
# -r 	Number of times to run racon (Default: 1)
# -t 	Threads (Default: 72)
# -m	Model used for medaka (Default: r104_e81_sup_g5015)
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

# Options
THREAD=72
MEDAK_MODEL='r104_e81_sup_g5015'
RACON_REPEAT=1

while getopts "r:t:m:" opts; do
case ${opts} in 
	r) 
		RACON_REPEAT=${OPTARG}
	;;
	t) 
		THREAD=${OPTARG}
	;;
	m)
		MEDAK_MODEL=${OPTARG}
	;;
	\?)
		echo "Not valid option"
		exit 1
	;;
esac
done

shift $((OPTIND-1))

NAME=${1}
shift
READS=$@

# File directories
CONTAINER_DIR='/projects/CanSeq/containers'
BUSCO_DB='/projects/CanSeq/scratch/nanopore_q20/busco_lineage_dataset/euarchontoglires_odb10'
REF_GENOME='/projects/alignment_references/Homo_sapiens/hg38_no_alt/genome/fasta/hg38_no_alt.fa'

# Functions 
check_success() {
	if [[ $? != 0 ]]; then
		echo "${1} unsuccessful" >> ${NAME}.log
		exit 1
	else
		echo "${1} completed successfully" >> ${NAME}.log
	fi
}

# Creating log file
echo "Running pipeline on ${NAME}" > ${NAME}.log
echo '' >> ${NAME}.log

################## 
#CONCATANATE READS 
##################
if [[ ! -f ${NAME}.reads.fastq.gz ]]; then 
	echo "Starting read file concatanation" >> ${NAME}.log
	cat ${READS} > ${NAME}.reads.fastq.gz
	echo "Concatanation completed" >> ${NAME}.log
else
	echo "Read file already concatanated" >> ${NAME}.log
fi

#########
#ASSEMBLY
#########

## FLYE (v2.9)
if [[ ! -f ${NAME}.flye_assembly/assembly.fasta ]]; then
	echo "Starting flye assembly" >> ${NAME}.log
	singularity exec -B /projects ${CONTAINER_DIR}/flye_3.9--py27h6a42192_0.sif flye --nano-hq ${NAME}.reads.fastq.gz --out-dir ${NAME}.flye_assembly --read-error 0.03 --threads ${THREAD}
	check_success "Flye assembly" 
else
	echo "Flye assembly already completed" >> ${NAME}.log
fi

################ 
#QUALITY CONTROL
################

## BUSCO (v5.2.2)
ulimit -u 100000

if [[ ! -f ${NAME}.busco_flye/run_euarchontoglires_odb10/short_summary.txt ]]; then
	echo "Starting busco on flye assembly" >> ${NAME}.log
	singularity exec -B /projects ${CONTAINER_DIR}/busco_5.2.2--pyhdfd78af_0.sif /usr/local/bin/busco -i ${NAME}.flye_assembly/assembly.fasta -m genome -o ${NAME}.busco_flye -l ${BUSCO_DB} -c ${THREAD}
	check_success "Busco (Flye)"
else
	echo "Busco (Flye) already completed" >> ${NAME}.log
fi 

## QUAST (v5.0.2)
if [[ ! -f ${NAME}.quast_flye/report.txt ]]; then
	echo "Starting quast on flye assembly" >> ${NAME}.log
	singularity exec -B /projects ${CONTAINER_DIR}/quast_5.0.2--py37pl5262hfecc14a_5.sif /usr/local/bin/quast.py ${NAME}.flye_assembly/assembly.fasta -r ${REF_GENOME} -o ${NAME}.quast_flye -t ${THREAD}
	check_success "Quase (Flye)"
else
	echo "Quast (Flye) already completed" >> ${NAME}.log
fi

##########
#POLISHING
##########
ASSEMBLY="${NAME}.flye_assembly/assembly.fasta"

for (( i = 1; i <= ${RACON_REPEAT}; i++ ))
do
	## MINIMAP2 (v2.22)
	if [[ ! -f ${NAME}.overlap${i}.paf ]]; then
		echo "Starting minimap2 (round ${i})" >> ${NAME}.log
		singularity exec -B /projects ${CONTAINER_DIR}/minimap2_2.22--h5bf99c6_0.sif minimap2 -t ${THREAD} -xmap-ont ${ASSEMBLY} ${NAME}.reads.fastq.gz > ${NAME}.overlap${i}.paf 2>/dev/null
		check_success "Minimap2 (round ${i})"
	else
		echo "Minimap2 (round ${i}) already completed" >> ${NAME}.log
	fi 
	
	## RACON (1.4.20) 
	if [[ ! -f ${NAME}.assembly.racon_${i}.fastq ]]; then
		echo "Starting racon (round ${i})" >> ${NAME}.log
		singularity exec -B /projects ${CONTAINER_DIR}/racon_1.4.20--h9a82719_1.sif racon -t ${THREAD} -m 8 -x -6 -g -8 -w 500 ${NAME}.reads.fastq.gz ${NAME}.overlap${i}.paf ${ASSEMBLY} > ${NAME}.assembly.racon_${i}.fastq 2> /dev/null
		check_success "Racon (round ${i})"
	else
		echo "Racon (round ${i}) already completed" >> ${NAME}.log
	fi
	
	ASSEMBLY="${NAME}.assembly.racon_${i}.fastq"
done

## MEDAKA (1.4.4)	
if [[ ! -f ${NAME}.medaka/consensus.fasta ]]; then 
	echo "Starting Medaka" >> ${NAME}.log
	singularity exec -B /projects ${CONTAINER_DIR}/medaka_1.4.4--py38h130def0_0.sif medaka_consensus -i ${NAME}.reads.fastq.gz -d ${ASSEMBLY} -o ${NAME}.medaka -t ${THREAD} -m ${MEDAK_MODEL}
	check_success "Medaka"
else
	echo "Medaka already completed" >> ${NAME}.log
fi

## BUSCO (v5.2.2)
if [[ ! -f ${NAME}.busco_racon_medaka/run_euarchontoglires_odb10/short_summary.txt ]]; then
	echo "Starting Busco (Racon and medaka)" >> ${NAME}.log
	singularity exec -B /projects ${CONTAINER_DIR}/busco_5.2.2--pyhdfd78af_0.sif /usr/local/bin/busco -i ${NAME}.medaka/consensus.fasta -m genome -o ${NAME}.busco_racon_medaka -l ${BUSCO_DB} -c ${THREAD}
	check_success "Busco (racon, medaka)"
else
	echo "Busco (Racon, medaka) already completed" >> ${NAME}.log
fi

## QUAST (v5.0.2)
if [[ ! -f ${NAME}.quast_racon_medaka/report.txt ]]; then
	echo "Starting quast (racon and medaka)" >> ${NAME}.log
	singularity exec -B /projects ${CONTAINER_DIR}/quast_5.0.2--py37pl5262hfecc14a_5.sif /usr/local/bin/quast.py ${NAME}.medaka/consensus.fasta -r ${REF_GENOME} -o ${NAME}.quast_racon_medaka -t ${THREAD}
	check_success "Quast (racon, medaka)"
else
	echo "Quast (Racon and medaka) already completed" >> ${NAME}.log
fi

###########
# STITCHING
###########

# Make longstich directory and symlink files into directory 
mkdir ${NAME}.longstich

ln -s ${NAME}.reads.fastq.gz ${NAME}.longstitch/${NAME}.reads.fq.gz
ln -s ${NAME}.medaka/consensus.fasta ${NAME}.longstitch/${NAME}.assembly.fa

cd ${NAME}.longstitch

## LONGSTITCH (1.0.1)
if [[ ! -f  ${NAME}.assembly.k32.w100.tigmint-ntLink-arks.longstitch-scaffolds.fa ]]
	echo "Starting LongStitch" >> ${NAME}.log
	singularity exec -B /projects ${CONTAINER_DIR}/longstitch_1.0.1--hdfd78af_1.sif longstitch tigmint-ntLink-arks draft=${NAME}.assembly.fa reads=q20.reads t=${THREAD} G=2e9 z=100
	check_success "LongStitch"
else
	echo "LongStitch already completed" >> ${NAME}.log
fi

cd ..
ln -s ${NAME}.longstitch/${NAME}.assembly.k32.w100.tigmint-ntLink-arks.longstitch-scaffolds.fa ${NAME}.FINAL_ASSEMBLY.fa

## BUSCO (v5.2.2)
if [[ ! -f ${NAME}.busco_longstitch/run_euarchontoglires_odb10/short_summary.txt ]]; then
	echo "Starting Busco (LongStitch)" >> ${NAME}.log
	singularity exec -B /projects ${CONTAINER_DIR}/busco_5.2.2--pyhdfd78af_0.sif /usr/local/bin/busco -i ${NAME}.FINAL_ASSEMBLY.fa -m genome -o ${NAME}.busco_longstitch -l ${BUSCO_DB} -c ${THREAD}
	check_success "Busco (LongStitch)"	
else
	echo "Busco (LongStitch) already completed" >> ${NAME}.log
fi

## QUAST (v5.0.2)
if [[ ! -f ${NAME}.quast_longstitch/report.txt ]]; then
	echo "Starting quast (LongStitch)" >> ${NAME}.log
	singularity exec -B /projects ${CONTAINER_DIR}/quast_5.0.2--py37pl5262hfecc14a_5.sif /usr/local/bin/quast.py ${NAME}.FINAL_ASSEMBLY.fa -r ${REF_GENOME} -o ${NAME}.quast_longstitch -t ${THREAD}
	check_success "Quast (LongStitch)"
else
	echo "Quast (LongStitch) already completed" >> ${NAME}.log
fi


exit 0
