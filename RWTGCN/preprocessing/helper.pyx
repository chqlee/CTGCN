import numpy as np
import pandas as pd
import os, json
from numpy import random
import scipy.sparse as sp
cimport numpy as np
import time
cimport cython

def random_walk(original_graph, structural_graph, node_list, walk_dir_path, freq_dir_path, f_name, tensor_dir_path,
                int walk_length, int walk_time, double prob, bint weight):
    # t1 = time.time()
    original_graph_dict, structural_graph_dict = {}, {}
    # preprocessing
    for node in node_list:
        original_neighbors = list(original_graph.neighbors(node))
        # cdef int neighbor_size = len(original_neighbors)
        original_weight = np.array([original_graph[node][neighbor]['weight'] for neighbor in original_neighbors])
        original_graph_dict[node] = {'neighbor': original_neighbors}
        original_graph_dict[node]['weight'] = original_weight / original_weight.sum()

        structural_neighbors = list(structural_graph.neighbors(node))
        structural_weight = np.array([structural_graph[node][neighbor]['weight'] for neighbor in structural_neighbors])
        structural_graph_dict[node] = {'neighbor': structural_neighbors}
        structural_graph_dict[node]['weight'] = structural_weight / structural_weight.sum()
    # t2 =time.time()
    #print('build graph time: ', t2 - t1, ' seconds!')

    node_num = len(node_list)
    nid2idx_dict = dict(zip(node_list, np.arange(node_num).tolist()))

    spmat_list, node_count_list, all_count_list = [sp.lil_matrix(1,1)], [[]], [-1]
    spmat_list += [sp.lil_matrix((node_num, node_num)) for i in range(walk_length)]
    node_count_list += [np.zeros(node_num, dtype=int).tolist() for i in range(walk_length)]
    all_count_list += np.zeros(walk_length, dtype=int).tolist()

    walk_graph_dict = dict(zip(node_list, [{}] * node_num))

    cdef int iter
    cdef int num = node_num
    cdef int nidx
    cdef int seq_len
    cdef int i
    cdef int j
    cdef int cnt = 1
    cdef int maxnum = walk_length + 1
    t1 = time.time()
    # print('start random walk！')
    # random walk
    for nidx in range(num):
        for iter in range(walk_time):
            # print('nidx = ', nidx)
            start_node = node_list[nidx]
            eps = 1e-8
            walk = [start_node]
            cnt = 1
            while cnt < maxnum:
                cur = walk[-1]
                rd = random.random()
                if rd <= prob + eps:
                    neighbors = original_graph_dict[cur]['neighbor']
                    weights = original_graph_dict[cur]['weight']
                else:
                    neighbors = structural_graph_dict[cur]['neighbor']
                    weights = structural_graph_dict[cur]['weight']
                if len(neighbors) == 0:
                    break
                walk.append(random.choice(neighbors, p=weights) if weight else random.choice(neighbors))
                cnt += 1

            seq_len = len(walk)
            for i in range(seq_len):
                for j in range(i + 1, seq_len):
                    step = j - i
                    left_idx = nid2idx_dict[walk[i]]
                    right_idx = nid2idx_dict[walk[j]]
                    # generate sparse node co-occurrence matrices
                    spmat = spmat_list[step]
                    node_count = node_count_list[step]
                    spmat[left_idx, right_idx] += 1
                    spmat[right_idx, left_idx] += 1
                    node_count[left_idx] += 1
                    node_count[right_idx] += 1
                    all_count_list[step] += 2
                    # generate walk pairs
                    walk_graph_dict[walk[i]][walk[j]] = 1
                    walk_graph_dict[walk[j]][walk[i]] = 1
    del original_graph_dict
    del structural_graph_dict

    for node, item_dict in walk_graph_dict.items():
        walk_graph_dict[node] = list(item_dict.keys())
    walk_file_path = os.path.join(walk_dir_path, f_name.split('.')[0] + '.json')
    with open(walk_file_path, 'w') as fp:
        json.dump(walk_graph_dict, fp)
    # print('write file!')
    del walk_graph_dict

    cdef int idx = 0
    node_freq_arr = np.array(node_count_list[1])
    for idx in range(2, walk_length + 1):
        node_freq_arr += np.array(node_count_list[idx])
    tot_freq = node_freq_arr.sum()
    Z = 0.001
    neg_node_list = []
    for nidx in range(num):
        neg_node_list += [node_list[nidx]] * int(((node_freq_arr[nidx]/tot_freq)**0.75)/Z)
    walk_file_path = os.path.join(freq_dir_path, f_name.split('.')[0] + '.json')
    with open(walk_file_path, 'w') as fp:
        json.dump(neg_node_list, fp)
    del neg_node_list

    for idx in range(1, walk_length + 1):
        spmat = spmat_list[idx].tocoo()
        node_count = node_count_list[idx]
        all_count = all_count_list[idx]
        df_PPMI = pd.DataFrame({'row': spmat.row, 'col': spmat.col, 'data': spmat.data}, dtype=int)

        def calc_PPMI(series):
            res = np.log(series['data'] * all_count / (node_count[series['row']] * node_count[series['col']]))
            if res < 0:
                return 0
            return res
        df_PPMI['data'] = df_PPMI.apply(calc_PPMI, axis=1)
        spmat = sp.coo_matrix((df_PPMI['data'], (df_PPMI['row'], df_PPMI['col'])), shape=(node_num, node_num))
        sp.save_npz(os.path.join(tensor_dir_path, str(idx) + ".npz"), spmat)
    # print('finish calc PPMI and save files!')
    # t3 = time.time()
    # print('PPMI calculation time: ', t3 - t2, ' seconds!')

# get unique values from array with tolerance=1e-12
def uniquetol(data_arr, cluster=False):
    idx_arr = np.argsort(data_arr)
    data_num = len(idx_arr)
    idx_order_dict = dict(zip(idx_arr.tolist(), np.ones(data_num).tolist()))
    cdef int pos = 0
    value = 1
    cdef int max_num = data_num
    while pos < max_num:
        idx_order_dict[idx_arr[pos]] = value
        while(pos + 1 < max_num):
            if np.abs(data_arr[idx_arr[pos]] - data_arr[idx_arr[pos + 1]]) >= 1e-12:
                value += 1
                break
            idx_order_dict[idx_arr[pos + 1]] = value
            pos += 1
        pos += 1
    cluster_dict = dict()
    def map_func(idx):
        label = idx_order_dict[idx]
        if cluster == True:
            if label not in cluster_dict:
                cluster_dict[label] = [idx]
            else:
                cluster_dict[label].append(idx)
        return label
    vfunc = np.vectorize(map_func)
    labels = vfunc(np.arange(data_num))
    if cluster == True:
        return labels, cluster_dict
    return labels