#!/usr/bin/env nextflow

fasta_file = Channel.fromPath(params.input)


process create_output {

    label 'fast'

    publishDir path: { "${params.general_output}" }, mode:'copy'

    output:
    path "clustering/fastas/"
    path "phylogenomics/aln/"
    path "phylogenomics/trim_aln/"
    path "phylogenomics/trees/"
    path "orthology/"


    script:
    """
    mkdir -p clustering/fastas/
    mkdir -p phylogenomics/aln/
    mkdir -p phylogenomics/trim_aln/
    mkdir -p phylogenomics/trees/
    mkdir -p orthology/
    """

}

process pfam_clustering {

    tag { fasta_file }

    publishDir path:  "${params.clustering_output}" , mode:'copy'

    input:
    path fasta_file

    output:
    path "result_hmm_mapper.emapper.hmm_hits", emit: pfam_table

    script:
    """
    python ${params.emapper_dir}/hmm_mapper.py \
        --cut_ga --clean_overlaps clans --usemem \
        --num_servers ${params.hmmer_num_servers} --num_workers ${params.hmmer_num_workers} --cpu ${params.hmmer_cpu} \
        --dbtype hmmdb  -d ${params.emapper_dir}/data/pfam/Pfam-A.hmm \
        --hmm_maxhits 0 --hmm_maxseqlen 60000 \
        --qtype seq -i ${fasta_file} -o result_hmm_mapper  
    """

}

process get_pfam_fastas {

    label 'medium'

    tag { pfam_table }

    memory { params.memory * task.attempt }
    time { params.time * task.attempt }

    errorStrategy { task.exitStatus in 137..140 ? 'retry' : 'terminate' }
    maxRetries 2

    publishDir path: "${params.fastas_output}" , mode: 'copy'

    input:
    path pfam_table

    output:
    path "*.pfam.faa", emit: pfam_fastas
    path "seqs_no_pfam.faa", emit: seqs_no_pfam
    path "pairs_small_pfamsfams.tsv", emit: pairs_small_pfams
    
    script:
    $/
    #!/usr/bin/env python    
    
    import sys
    import os
    from Bio import SeqIO
    from collections import defaultdict
    
    pfam2seqs = defaultdict(set)
    
    with open("${pfam_table}") as fin:
        for line in fin:
            if not line.startswith("#"):
                info = line.strip().split("\t")
                pfam2seqs[info[1]].add(info[0])
                #seqs2pfam[info[0]].add(info[1])
    
    seqs2pfam = defaultdict(set)
    small_pfam_fams = list()
    for pfam, seqs in pfam2seqs.items():
        if len(seqs) >= 3:
            for s in seqs:
                seqs2pfam[s].add(pfam)


        if len(seqs) == 2:
            tax1 = list(seqs)[0].split('.')
            tax2 = list(seqs)[1].split('.')
            if tax1 != tax2:
                small_pfam_fams.append(list(seqs))

    if len(small_pfam_fams) >0:
        print(small_pfam_fams)
        with(open('pairs_small_pfamsfams.tsv', 'w')) as fout:
            for el in small_pfam_fams:
                print(el)
                fout.write('\t'.join(el)+'\n')

    seqs_no_pfam_path = "seqs_no_pfam.faa"
    seqs_no_pfam = open(seqs_no_pfam_path, 'w')
    
    for record in SeqIO.parse("${params.input}", "fasta"):
        if record.id in seqs2pfam.keys():
           for dom in seqs2pfam[record.id]:
                path2pfam_fasta =  dom + ".pfam.faa"
                with open(path2pfam_fasta, "a") as fout:
                    fout.write(">"+record.id+"\n"+str(record.seq)+"\n")
                    fout.close()
        else:
            seqs_no_pfam.write(">"+record.id+"\n"+str(record.seq)+"\n")
    
    seqs_no_pfam.close()
    /$

    
}

process mmseqs_clustering {

    label 'medium'

    tag { seqs_no_pfam }

    memory { params.memory * task.attempt }
    time { params.time * task.attempt }

    errorStrategy { task.exitStatus in 137..140 ? 'retry' : 'terminate' }
    maxRetries 2

    publishDir path: "${params.clustering_output}" , mode: 'copy'

    input:
    path seqs_no_pfam


    output:
    path "seqs_no_pfam.clusters_mem.tsv", emit: mmseqs_mems
    path "seqs_no_pfam.clusters_size.tsv"
    path "seqs_no_pfam.clusters.tsv"


    script:
    mmseqs_db = "seqs_no_pfam.mmseqs_db"
    mmseqs_clustering = "seqs_no_pfam.cluster_db"
    mmseqs_tsv = "seqs_no_pfam.clusters.tsv"
    mmseqs_mems = "seqs_no_pfam.clusters_mem.tsv"
    mmseqs_size = "seqs_no_pfam.clusters_size.tsv"
    """
        mkdir mmseqs_tmp

        mmseqs createdb ${seqs_no_pfam} ${mmseqs_db}
        
        mmseqs cluster ${mmseqs_db} ${mmseqs_clustering} mmseqs_tmp --threads ${params.mmseqs_threads} \
        -c ${params.mmseqs_coverage} --min-seq-id ${params.mmseqs_min_seq_id} -s ${params.sensitivity} \
        --cov-mode ${params.cov_mode} --cluster-mode ${params.cluster_mode}
       
        mmseqs createtsv ${mmseqs_db} ${mmseqs_db} ${mmseqs_clustering} ${mmseqs_tsv}
       
        cat ${mmseqs_tsv} | datamash -g1 collapse 2 > ${mmseqs_mems}

        cat ${mmseqs_tsv} | datamash -g1 countunique 2 > ${mmseqs_size}
    """
}


process get_mmseqs_fastas {

    label 'medium'

    tag { mmseqs_mems }

    memory { params.memory * task.attempt }
    time { params.time * task.attempt }

    errorStrategy { task.exitStatus in 137..140 ? 'retry' : 'terminate' }
    maxRetries 2


    publishDir path: "${params.fastas_output}" , mode: 'copy'

    input:
    path mmseqs_mems
    path seqs_no_pfam

    output:
    path "*.mmseqs.faa" , emit: mmseqs_fastas
    path "singletons.faa", emit: singletons
    path "pairs_small_mmseqs.tsv", emit: pairs_small_mmseqs

    script:
    $/
    #!/usr/bin/env python   

    from Bio import SeqIO
    from collections import defaultdict

    mmseqs_clus2seqs = defaultdict(list)
    seqs2mmseqs = defaultdict()    
    sigletons_fasta = open("singletons.faa", "w")
    pairs_small_mmseqs = list()

    with open("${mmseqs_mems}") as fin:
        for line in fin:
            if not line.startswith("#"):
                info = line.strip().split("\t")
                if len(info[1].split(',')) >=3:
                    mmseqs_clus2seqs[info[0]] = info[1].split(',')
                    for s in info[1].split(','):
                        seqs2mmseqs[s] = info[0]

                if len(info[1].split(',')) == 2:
                    seqs_list = info[1].split(',')
                    tax1 = seqs_list[0].split('.')[1]
                    tax2 = seqs_list[1].split('.')[1]
                    if tax1 != tax2:
                        pairs_small_mmseqs.append(seqs_list)

    if len(pairs_small_mmseqs)>0:
        with(open('pairs_small_mmseqs.tsv', 'w')) as fout:
            for el in pairs_small_mmseqs:
                fout.write('\t'.join(el)+'\n')

    for record in SeqIO.parse("${seqs_no_pfam}", "fasta"):
        if record.id in seqs2mmseqs.keys():
            mmseqs_name = seqs2mmseqs[record.id]
            path2mmseqs_fasta = mmseqs_name + ".mmseqs.faa"
            with open(path2mmseqs_fasta, "a") as fout:
                fout.write(">"+record.id+"\n"+str(record.seq)+"\n")
                fout.close()

        else:
            sigletons_fasta.write(">"+record.id+"\n"+str(record.seq)+"\n")

    sigletons_fasta.close()
    /$
}


process align_pfam {

    label 'medium'

    tag { raw_pfam_fasta }

    memory { params.memory * task.attempt }
    time { params.time * task.attempt }

    errorStrategy {
    if (task.exitStatus in 137..140) {
        // Exponential backoff strategy: delay increases with each retry
        sleep(Math.pow(2, task.attempt) * 200 as long)
        return 'retry'
    } else {
        return 'ignore'
    }
    }
    maxRetries 3

    publishDir path: { "${params.phylogenomics_output}/aln/" }, mode: 'copy'

    input:
    path raw_pfam_fasta 

    output:
    path "*.pfam.aln", emit: pfam_aln
        
    script:
    fasta_name = raw_pfam_fasta.baseName
    """
    famsa -t ${params.famsa_threads} ${raw_pfam_fasta} ${fasta_name}.aln 2> align.err  
    """

}

process align_mmseqs {

    label 'medium'

    tag { raw_mmseqs_fasta }

    memory { params.memory * task.attempt }
    time { params.time * task.attempt }

    errorStrategy {
    if (task.exitStatus in 137..140) {
        // Exponential backoff strategy: delay increases with each retry
        sleep(Math.pow(2, task.attempt) * 200 as long)
        return 'retry'
    } else {
        return 'ignore'
    }
    }
    maxRetries 3

    publishDir path: { "${params.phylogenomics_output}/aln/" }, mode: 'copy'

    input:
    path raw_mmseqs_fasta

    output:
    path "*.mmseqs.aln", emit: mmseqs_aln
    
    
    script:
    fasta_name = raw_mmseqs_fasta.baseName
    """
    famsa -t ${params.famsa_threads} ${raw_mmseqs_fasta} ${fasta_name}.aln 2> align.err
    """

}


process trimming_pfam {

    label 'fast'

    tag { pfam_aln }

    memory { params.memory * task.attempt }
    time { params.time * task.attempt }

    errorStrategy {
    if (task.exitStatus in 137..140) {
        // Exponential backoff strategy: delay increases with each retry
        sleep(Math.pow(2, task.attempt) * 200 as long)
        return 'retry'
    } else {
        return 'ignore'
    }
    }
    maxRetries 3

    publishDir path: { "${params.phylogenomics_output}/trim_aln/" }, mode: 'copy'

    input:
    path pfam_aln

    output:
    path "*pfam.trim", emit: pfam_trim

    script:
    fasta_name = pfam_aln.baseName
    """
    ${params.python_version} ${params.bin_dir}trim_alg_v2.py -i ${pfam_aln} --min_res_abs 3 --min_res_percent 0.1 -o ${fasta_name}.trim
    """

}

process trimming_mmseqs{

    label 'fast'
    
    tag { mmseqs_aln }

    memory { params.memory * task.attempt }
    time { params.time * task.attempt }

    errorStrategy {
    if (task.exitStatus in 137..140) {
        // Exponential backoff strategy: delay increases with each retry
        sleep(Math.pow(2, task.attempt) * 200 as long)
        return 'retry'
    } else {
        return 'ignore'
    }
    }
    maxRetries 3

    publishDir path: { "${params.phylogenomics_output}/trim_aln/" }, mode: 'copy'

    input:
    path mmseqs_aln

    output:
    path "*.mmseqs.trim", emit: mmseqs_trim

    script:
    fasta_name = mmseqs_aln.baseName
    """
    ${params.python_version} ${params.bin_dir}trim_alg_v2.py -i ${mmseqs_aln} --min_res_abs 3 --min_res_percent 0.1 -o ${fasta_name}.trim
    """

}

process tree_pfam {

    label 'medium'

    tag { pfam_trim }

    memory { params.memory * task.attempt }
    time { params.time * task.attempt }

    errorStrategy {
    if (task.exitStatus in 137..140) {
        // Exponential backoff strategy: delay increases with each retry
        sleep(Math.pow(2, task.attempt) * 200 as long)
        return 'retry'
    } else {
        return 'ignore'
    }
    }
    maxRetries 3

    publishDir path: { "${params.phylogenomics_output}/trees/" }, mode: 'copy'

    input:
    path pfam_trim

    output:
    path "*.pfam.nw", emit: pfam_nw


    script:
    fasta_name = pfam_trim.baseName
    """
    if [ ${task.attempt} -gt 1 ]
    then    
        FastTree -fastest  ${pfam_trim}  > ${fasta_name}.nw  
    else 
        FastTree ${pfam_trim} > ${fasta_name}.nw 
    fi
    """
}


process tree_mmseqs {

    label 'medium'

    tag { mmseqs_trim }

    memory { params.memory * task.attempt }
    time { params.time * task.attempt }

    errorStrategy {
    if (task.exitStatus in 137..140) {
        // Exponential backoff strategy: delay increases with each retry
        sleep(Math.pow(2, task.attempt) * 200 as long)
        return 'retry'
    } else {
        return 'ignore'
    }
    }
    maxRetries 3

    publishDir path: { "${params.phylogenomics_output}/trees/" }, mode: 'copy'

    input:
    path mmseqs_trim

    output:
    path "*.mmseqs.nw", emit: mmseqs_nw


    script:
    fasta_name = mmseqs_trim.baseName
    """
    FastTree ${mmseqs_trim} > ${fasta_name}.nw  
    """
}

process ogd_pfam {

    label 'medium'

    tag { pfam_nw }

    memory { params.memory * task.attempt }
    time { params.time * task.attempt }

    errorStrategy {
    if (task.exitStatus in 137..140) {
        // Exponential backoff strategy: delay increases with each retry
        sleep(Math.pow(2, task.attempt) * 200 as long)
        return 'retry'
    } else {
        return 'ignore'
    }
    }
    maxRetries 3


    publishDir path: { "${params.orthology_output}/${fasta_name}/" }, mode: 'copy'

    input:
    path pfam_nw

    output:
    path "*.tree_annot.nw", emit: ogd_pfam_tree
    path "*.ogs_info.tsv", emit: ogd_pfam_info
    path "*.seq2ogs.tsv", emit: ogd_pfam_seq2og 
    path "*.pairs.tsv", emit: ogd_pfam_pairs 

    script:
    fasta_name = pfam_nw.baseName
    """
    mkdir -p ${params.orthology_output}/${fasta_name}
    ${params.python_version} ${params.ogd_dir}og_delineation.py --tree ${pfam_nw} --output_path ./  \
        --rooting ${params.ogd_rooting} --user_taxonomy ${params.ogd_taxonomy_db} --sp_delimitator  ${params.ogd_sp_delimitator}
    """


}


process ogd_mmseqs {

    label 'medium'

    tag { mmseqs_nw }

    memory { params.memory * task.attempt }
    time { params.time * task.attempt }

    errorStrategy {
    if (task.exitStatus in 137..140) {
        // Exponential backoff strategy: delay increases with each retry
        sleep(Math.pow(2, task.attempt) * 200 as long)
        return 'retry'
    } else {
        return 'ignore'
    }
    }
    maxRetries 3

    publishDir path: { "${params.orthology_output}/${fasta_name}/" }, mode: 'copy'

    input:
    path mmseqs_nw

    output:
    path "*.tree_annot.nw", emit: ogd_mmseqs_tree 
    path "*.ogs_info.tsv", emit: ogd_mmseqs_info
    path "*.seq2ogs.tsv", emit: ogd_mmseqs_seq2og
    path "*.pairs.tsv", emit: ogd_mmseqs_pairs 


    script:
    fasta_name = mmseqs_nw.baseName
    """
    mkdir  -p ${params.orthology_output}/${fasta_name}
    ${params.python_version} ${params.ogd_dir}og_delineation.py --tree ${mmseqs_nw} --output_path ./   \
        --rooting ${params.ogd_rooting} --user_taxonomy ${params.ogd_taxonomy_db} --sp_delimitator  ${params.ogd_sp_delimitator}     
    """

}

workflow {

    create_output()

    pfam_clustering(fasta_file)

    get_pfam_fastas(pfam_clustering.out.pfam_table)

    align_pfam(get_pfam_fastas.out.pfam_fastas.flatten())

    trimming_pfam(align_pfam.out.pfam_aln)

    tree_pfam(trimming_pfam.out.pfam_trim)

    ogd_pfam(tree_pfam.out.pfam_nw)


    
    mmseqs_clustering(get_pfam_fastas.out.seqs_no_pfam)

    get_mmseqs_fastas(mmseqs_clustering.out.mmseqs_mems, get_pfam_fastas.out.seqs_no_pfam)

    align_mmseqs(get_mmseqs_fastas.out.mmseqs_fastas.flatten())

    trimming_mmseqs(align_mmseqs.out.mmseqs_aln)

    tree_mmseqs(trimming_mmseqs.out.mmseqs_trim)

    ogd_mmseqs(tree_mmseqs.out.mmseqs_nw)    
    

}