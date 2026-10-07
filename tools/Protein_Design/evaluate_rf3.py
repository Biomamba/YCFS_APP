#!/usr/bin/env python3
"""Evaluate two-protein RF3 designs. Requires numpy and biopython.

Default: root = this script's parent directory; receptor B, binder A.
iPAE = mean of both inter-chain PAE directions for C-alpha contact pairs within 8 Angstrom.
RMSDs use CA atoms and a SINGLE receptor-fitted rigid transform.
pLDDT = chain atom-weighted mean from confidences.json, normalized to 0..100.
"""
import argparse
import csv
import gzip
import json
import re
import sys
from pathlib import Path

import numpy as np
from Bio.PDB import MMCIFParser
from Bio.SeqUtils import seq1

FIELDS = '''batch design_id rfd3_design_id prediction_id ipae ipae_row_receptor_col_binder ipae_row_binder_col_receptor receptor_rmsd binder_rmsd_receptor_aligned iptm receptor_plddt binder_plddt plddt_input_scale ptm ranking_score has_clash reference_source reference_file receptor_ca_count binder_ca_count rf3_model confidences_file summary_file status notes selection seed sample receptor_chain binder_chain receptor_length binder_length receptor_sequence binder_sequence'''.split()


def read_json(path):
    with path.open() as f:
        return json.load(f)


def structure(path):
    opener = gzip.open if path.suffix == '.gz' else open
    with opener(path, 'rt') as f:
        s = MMCIFParser(QUIET=True).get_structure('model', f)
    if len(s) != 1:
        raise ValueError('Expected one structural model')
    chains = {}
    for chain in s[0]:
        residues = [r for r in chain if r.id[0] == ' ' and 'CA' in r]
        if residues:
            chains[chain.id] = residues
    return chains


def ca(residues):
    return np.asarray([r['CA'].coord for r in residues], dtype=float)


def sequence(residues):
    return ''.join(seq1(r.resname) for r in residues)


def fit(mobile, target):
    if mobile.shape != target.shape or len(mobile) < 3:
        raise ValueError('Receptor fit needs >=3 matched CA atoms')
    mc, tc = mobile.mean(0), target.mean(0)
    x, y = mobile - mc, target - tc
    if min(np.linalg.matrix_rank(x), np.linalg.matrix_rank(y)) < 2:
        raise ValueError('Degenerate receptor coordinates')
    u, _, vt = np.linalg.svd(x.T @ y)
    correction = np.diag([1., 1., np.linalg.det(u @ vt)])
    rotation = u @ correction @ vt
    return rotation, tc - mc @ rotation


def rmsd(x, y):
    return float(np.sqrt(np.mean(np.sum((x - y) ** 2, axis=1))))


def token_mask(ids, chain):
    # RF3 token IDs are instance IDs (A_1), atom IDs are plain chains (A).
    unique = set(map(str, ids))
    matches = [x for x in unique if x == chain or re.fullmatch(re.escape(chain) + r'_\d+', x)]
    if len(matches) != 1:
        raise ValueError(f'Ambiguous/missing token instance for chain {chain}: {matches}')
    return np.asarray(ids, dtype=str) == matches[0]


def find_reference(root, batch, design, source, rfd3_dir=None):
    rfd = re.sub(r'_b\d+_d\d+$', '', design)
    sources = ['mpnn', 'rfd3'] if source == 'auto' else [source]
    for kind in sources:
        stem = design if kind == 'mpnn' else rfd
        dirs = [root/'mpnn'/batch] if kind == 'mpnn' else [root/'rfd3'/'outputs'/batch, root/'rfd3'/batch]
        if kind == 'rfd3' and rfd3_dir is not None:
            dirs = [rfd3_dir/batch]
        candidates = {d/(stem+ext) for d in dirs for ext in ['.cif', '.cif.gz'] if (d/(stem+ext)).is_file()}
        if len(candidates) > 1:
            raise ValueError(f'Ambiguous {kind} references: {sorted(map(str, candidates))}')
        if candidates:
            return kind, candidates.pop()
    raise FileNotFoundError(f'No matching {source} reference in batch {batch}: {design}')


def evaluate(path, root, args):
    sampled = bool(re.fullmatch(r'seed-\d+_sample-\d+', path.parent.name))
    folder = path.parent.parent if sampled else path.parent
    batch = folder.parent.relative_to(args.rf3_dir)
    design = folder.name
    pred = re.sub(r'_model\.cif(?:\.gz)?$', '', path.name)
    row = dict(batch=str(batch), design_id=design,
               rfd3_design_id=re.sub(r'_b\d+_d\d+$', '', design), prediction_id=pred,
               selection='sample' if sampled else 'best', receptor_chain=args.receptor_chain,
               binder_chain=args.binder_chain, rf3_model=str(path))
    notes = []
    conf_path = path.parent/(pred+'_confidences.json')
    summary_path = path.parent/(pred+'_summary_confidences.json')
    row.update(confidences_file=str(conf_path), summary_file=str(summary_path))
    match = re.search(r'_seed-(\d+)_sample-(\d+)$', pred)
    if match:
        row.update(seed=match[1], sample=match[2])
    else:
        ranking = folder/(design+'_ranking_scores.csv')
        if ranking.exists():
            try:
                with ranking.open() as f:
                    ranked = list(csv.DictReader(f))
                best = max(ranked, key=lambda r: float(r['ranking_score']))
                row.update(seed=best['seed'], sample=best['sample'])
            except Exception as e:
                notes.append(f'ranking: {e}')
    try:
        summary = read_json(summary_path)
        for key in ['iptm', 'ptm', 'ranking_score', 'has_clash']:
            row[key] = summary.get(key, '')
        if summary.get('iptm') is None:
            notes.append('iptm missing')
    except Exception as e:
        notes.append(f'summary: {e}')
    try:
        chains = structure(path)
        if set(chains) != {args.receptor_chain, args.binder_chain}:
            raise ValueError(f'Expected exactly the two selected protein chains; found {list(chains)}')
        for role, cid in [('receptor', args.receptor_chain), ('binder', args.binder_chain)]:
            row[role+'_length'] = len(chains[cid])
            row[role+'_sequence'] = sequence(chains[cid])
    except Exception as e:
        row.update(status='error', notes=f'structure: {e}')
        return row
    try:
        conf = read_json(conf_path)
    except Exception as e:
        conf = {}
        notes.append(f'confidence JSON: {e}')
    try:
        ids = conf['token_chain_ids']
        pae = np.asarray(conf['pae'], dtype=float)
        if pae.shape != (len(ids), len(ids)) or not np.isfinite(pae).all() or (pae < 0).any():
            raise ValueError('Invalid PAE matrix')
        r, b = token_mask(ids, args.receptor_chain), token_mask(ids, args.binder_chain)
        if r.sum() != row['receptor_length'] or b.sum() != row['binder_length'] or not (r | b).all():
            raise ValueError('PAE tokens do not match protein residue counts')
        contacts = np.linalg.norm(ca(chains[args.receptor_chain])[:, None, :] -
                                  ca(chains[args.binder_chain])[None, :, :], axis=2) <= 8.0
        if not contacts.any():
            raise ValueError('No receptor-binder C-alpha contacts within 8 Angstrom')
        rb = float(pae[np.ix_(r, b)][contacts].mean())
        br = float(pae[np.ix_(b, r)][contacts.T].mean())
        row.update(ipae=(rb+br)/2, ipae_row_receptor_col_binder=rb, ipae_row_binder_col_receptor=br)
    except Exception as e:
        notes.append(f'ipae: {e}')
    try:
        values = np.asarray(conf['atom_plddts'], dtype=float)
        ids = np.asarray(conf['atom_chain_ids'], dtype=str)
        if values.ndim != 1 or values.shape != ids.shape or not values.size or not np.isfinite(values).all() or values.min() < 0 or values.max() > 100:
            raise ValueError('Invalid atom pLDDT arrays')
        scale = args.plddt_scale
        if scale == 'auto':
            scale = '1' if values.max() <= 1 else '100'
        if values.max() > float(scale):
            raise ValueError('pLDDT exceeds selected input scale')
        row['plddt_input_scale'] = scale
        results = {}
        for role, cid in [('receptor', args.receptor_chain), ('binder', args.binder_chain)]:
            mask = ids == cid
            if not mask.any():
                raise ValueError(f'No atom confidence for {cid}')
            results[role+'_plddt'] = float(values[mask].mean()*100/float(scale))
        row.update(results)
    except Exception as e:
        notes.append(f'plddt: {e}')
    try:
        kind, ref = find_reference(root, batch, design, args.reference, args.rfd3_dir)
        row.update(reference_source=kind, reference_file=str(ref))
        refs = structure(ref)
        for role, cid in [('receptor', args.receptor_chain), ('binder', args.binder_chain)]:
            p, q = chains[cid], refs[cid]
            # Strict full-chain residue-ID correspondence: never silently fit partial overlap.
            if [x.id for x in p] != [x.id for x in q]:
                raise ValueError(f'{role}: residue IDs/length differ; explicit mapping required')
            if (role == 'receptor' or kind == 'mpnn') and sequence(p) != sequence(q):
                raise ValueError(f'{role}: sequence differs from {kind} reference')
        rc, bc = args.receptor_chain, args.binder_chain
        rotation, translation = fit(ca(chains[rc]), ca(refs[rc]))
        row.update(receptor_rmsd=rmsd(ca(chains[rc])@rotation+translation, ca(refs[rc])),
                   binder_rmsd_receptor_aligned=rmsd(ca(chains[bc])@rotation+translation, ca(refs[bc])),
                   receptor_ca_count=len(chains[rc]), binder_ca_count=len(chains[bc]))
    except Exception as e:
        notes.append(f'rmsd: {e}')
    row.update(status='partial' if notes else 'ok', notes='; '.join(notes))
    return row


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--root', type=Path, default=Path(__file__).resolve().parent.parent)
    ap.add_argument('--rf3-dir', type=Path, help='RF3 directory; default ROOT/rf3')
    ap.add_argument('--rfd3-dir', type=Path, help='RFD3 output directory, paired at the same batch depth as --rf3-dir; implies --reference rfd3 unless explicitly overridden')
    output_group = ap.add_mutually_exclusive_group()
    output_group.add_argument('--output', type=Path, help='Exact CSV path (relative to working directory)')
    output_group.add_argument('--csv-prefix', type=Path, help='Output prefix, optionally including a directory; relative to ROOT; appends .csv')
    ap.add_argument('--receptor-chain', default='B')
    ap.add_argument('--binder-chain', default='A')
    ap.add_argument('--reference', choices=['auto','mpnn','rfd3'], default=None)
    ap.add_argument('--models', choices=['best','all'], default='best', help='all uses seed/sample outputs, excluding top-level copies')
    ap.add_argument('--plddt-scale', choices=['auto','1','100'], default='auto')
    args = ap.parse_args()
    root = args.root.expanduser().resolve()
    args.rf3_dir = (args.rf3_dir.expanduser() if args.rf3_dir else root/'rf3').resolve()
    if not args.rf3_dir.is_dir():
        ap.error(f'RF3 directory does not exist: {args.rf3_dir}')
    if args.rfd3_dir is not None:
        args.rfd3_dir = args.rfd3_dir.expanduser().resolve()
        if not args.rfd3_dir.is_dir():
            ap.error(f'RFD3 directory does not exist: {args.rfd3_dir}')
    if args.reference is None:
        args.reference = 'rfd3' if args.rfd3_dir is not None else 'auto'
    if args.receptor_chain == args.binder_chain:
        ap.error('Receptor and binder chains must differ')
    paths = sorted(list(args.rf3_dir.rglob('*_model.cif')) + list(args.rf3_dir.rglob('*_model.cif.gz')))
    selected = [p for p in paths if bool(re.fullmatch(r'seed-\d+_sample-\d+', p.parent.name)) == (args.models == 'all')]
    if not selected:
        ap.error(f'No {args.models} RF3 model CIFs under {args.rf3_dir}')
    identities = [str(p).removesuffix('.gz') for p in selected]
    if len(set(identities)) != len(identities):
        ap.error('Duplicate compressed/uncompressed model files; retain only one version')
    if args.csv_prefix is not None:
        prefix = args.csv_prefix.expanduser()
        if not prefix.is_absolute():
            prefix = root/prefix
        output = Path(str(prefix) + '.csv').resolve()
    else:
        output = args.output.expanduser().resolve() if args.output else root/'rf3_evaluation.csv'
    output.parent.mkdir(parents=True, exist_ok=True)
    counts = {'ok':0, 'partial':0, 'error':0}
    with output.open('w', newline='', encoding='utf-8-sig') as f:
        writer = csv.DictWriter(f, fieldnames=FIELDS)
        writer.writeheader()
        for path in selected:
            row = evaluate(path, root, args)
            counts[row['status']] += 1
            writer.writerow({k: round(v,6) if isinstance(v,float) else v for k,v in row.items()})
            if row['status'] != 'ok':
                print(f"[{row['status']}] {row['batch']}/{row['design_id']}: {row['notes']}", file=sys.stderr)
    print(f'Wrote {len(selected)} rows to {output}; {counts}')
    return 1 if counts['partial'] or counts['error'] else 0


if __name__ == '__main__':
    sys.exit(main())
