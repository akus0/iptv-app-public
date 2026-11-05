"""Export audited current source without history, ignored files or local secrets."""
import argparse
import tempfile
from pathlib import Path
from audit_repository import private_values, read_source_entry, source_files, tracked_ignored_findings


def export_source(root, target):
    root = root.resolve()
    target = target.expanduser().resolve()
    if target == root or root in target.parents or target.exists():
        raise ValueError('Choose a new directory outside the checkout.')
    files = source_files(root)
    values = private_values(root)
    if tracked_ignored_findings(root, values):
        raise ValueError('Tracked files match ignore rules. Run tools/audit_repository.py and review them before export.')
    target.parent.mkdir(parents=True, exist_ok=True)
    # Publish only a complete snapshot. Failed audits/copies remove their
    # temporary output rather than leaving something that looks ready to share.
    with tempfile.TemporaryDirectory(prefix='.source-export-', dir=target.parent) as temporary:
        staging = Path(temporary) / 'source'
        staging.mkdir(mode=0o700)
        count = 0
        for name in files:
            data, executable, findings = read_source_entry(root, name, values)
            if findings:
                raise ValueError('Source audit failed. Run tools/audit_repository.py and resolve findings first.')
            if data is None:
                continue
            destination = staging / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            # Write the audited buffer, not a second read of the working file.
            # Copy no local extended attributes, ownership or timestamps.
            destination.write_bytes(data)
            destination.chmod(0o644 | executable)
            count += 1
        if source_files(root) != files:
            raise ValueError('Source file list changed during export. Retry from a quiet checkout.')
        if tracked_ignored_findings(root, values):
            raise ValueError('Ignore rules changed during export. Review tracked ignored files before retrying.')
        if target.exists():
            raise ValueError('Destination appeared during export; nothing was replaced.')
        staging.rename(target)
    return count


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('destination', type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    try:
        count = export_source(root, args.destination)
    except ValueError as error:
        parser.error(str(error))
    except OSError:
        parser.error('Could not read or write the snapshot. Check file access and available space.')
    print(f'Exported {count} source files without Git history or ignored files.')
    print('Review artwork/dependency rights and corresponding-source requirements before publishing.')


if __name__ == '__main__':
    main()
