"""Turn a folder of .arf report definitions into the layout file the app draws.

    python -I tool/arf_to_layouts.py <folder of .arf> assets/report_layouts/layouts.json

An .arf says where every piece of a report sits: which band it is in, its row
and column on a character grid, how long it is, its font and which way it is
justified, and whether it is fixed text, a field of the data, one of the five
system values (the shop, the report, when it was run) or a rule across the page.
It also carries the report's rules: the fields it computes, the rows it leaves
out and the fields it totals. All of that is kept; the rest (GUIDs, lookup
tables, the vendor's filter plumbing) is dropped.
"""
import glob
import json
import os
import sys
import xml.etree.ElementTree as ET

KINDS = {'Text': 't', 'Variable': 'v', 'System variable': 's', 'Line': 'l'}


def number(element, tag):
    try:
        return int(element.findtext(tag) or 0)
    except ValueError:
        return 0


def cell(detail):
    kind = KINDS.get(detail.findtext('Name') or '')
    if kind is None:
        return None
    out = {
        'k': kind,
        'r': number(detail, 'Row'),
        'c': number(detail, 'Column'),
        'n': number(detail, 'Length'),
        'fs': number(detail, 'FontSize') or 9,
        'j': number(detail, 'Justify'),
    }
    for flag, tag in (('b', 'Bold'), ('u', 'Underline'), ('i', 'Italic')):
        if number(detail, tag):
            out[flag] = 1
    if kind == 't':
        out['x'] = detail.findtext('Text') or ''
    elif kind in ('v', 's'):
        out['x'] = detail.findtext('Variable') or ''
    if kind == 'v':
        out['f'] = number(detail, 'FormatStyle')
    return out


def band(layout, name):
    element = layout.find(name)
    if element is None:
        return []
    return [c for c in (cell(d) for d in element.findall('Detail')) if c]


def tokens(rule):
    return [
        [number(t, 'TokenType'), t.findtext('TokenValue') or '']
        for t in rule.findall('Tokens/Token')
    ]


def rule(element):
    name = element.findtext('Name') or ''
    out = {'name': name}
    on = (element.findtext('itemFullName') or element.findtext('iterateFullName')
          or element.findtext('iterateFullname'))
    if on:
        out['on'] = on
    field = element.findtext('newfield')
    if field:
        out['field'] = field
    expression = tokens(element)
    if expression:
        out['tokens'] = expression
    sums = [f.text or '' for f in element.findall('FieldsToSum/Field')]
    if sums:
        out['sum'] = sums
    # A rule with nothing the app can act on is the vendor's own plumbing.
    return out if len(out) > 1 else None


def report(path):
    root = ET.parse(path).getroot()
    blocks = []
    for block in root.findall('ReportBlocks/ReportBlock'):
        layouts = []
        for layout in block.findall('DataItemLayouts/DataItemLayout'):
            entry = {
                'what': layout.findtext('LayoutWhat') or '',
                'header': band(layout, 'Header'),
                'details': band(layout, 'Details'),
                'summary': band(layout, 'Summary'),
            }
            if number(layout, 'Orientation'):
                entry['landscape'] = 1
            if entry['header'] or entry['details'] or entry['summary']:
                layouts.append(entry)
        rules = [r for r in (rule(e) for e in block.findall('Rules/Rule')) if r]
        if layouts or rules:
            blocks.append({
                'type': block.findtext('TreeBuilder/Type') or '',
                'layouts': layouts,
                'rules': rules,
            })
    return {
        'id': os.path.splitext(os.path.basename(path))[0],
        'name': root.findtext('ReportName') or '',
        'group': root.findtext('DefaultGroup') or '',
        'blocks': blocks,
    }


def main():
    source, target = sys.argv[1:3]
    reports = [report(p) for p in sorted(glob.glob(os.path.join(source, '*.arf')))]
    reports.sort(key=lambda r: (r['group'], r['name'], r['id']))
    os.makedirs(os.path.dirname(target), exist_ok=True)
    with open(target, 'w', encoding='utf-8', newline='\n') as out:
        json.dump(reports, out, ensure_ascii=False, separators=(',', ':'))
        out.write('\n')
    print(len(reports), 'reports ->', target)


if __name__ == '__main__':
    main()
