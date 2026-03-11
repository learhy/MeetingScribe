#!/usr/bin/env python3
"""CLI for managing the speaker database.

Usage:
    speaker_cli.py [--json] [--db PATH] <command> [args...]

Commands:
    list-pending                    Show pending name suggestions
    confirm <suggestion_id>         Accept a name suggestion
    reject <suggestion_id>          Reject a name suggestion
    list-speakers                   Show all known speakers
    get-speaker <speaker_id>        Get details for one speaker
    rename <speaker_id> <name>      Manually set speaker name
    merge <keep_id> <merge_id>      Merge duplicate speakers
    split <speaker_id> <emb_ids>    Split incorrectly merged speaker
    delete <speaker_id>             Delete a speaker
    stats                           Show database statistics
    cleanup                         Run maintenance cleanup
    check                           Run integrity checks
    backup                          Create a backup
    export <speaker_id>             Export speaker data (GDPR)

Options:
    --json      Output in JSON format (for programmatic access)
    --db PATH   Database path (default: ~/.meetingscribe/speaker.db)
"""
import argparse
import json
import sys
from dataclasses import asdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional

from speaker_db import SpeakerDatabase, SpeakerDBError

DEFAULT_DB_PATH = Path.home() / '.meetingscribe' / 'speaker.db'


# =============================================================================
# JSON Output Helpers
# =============================================================================

class JSONEncoder(json.JSONEncoder):
    """Handle datetime and dataclass serialization."""
    
    def default(self, obj):
        if isinstance(obj, datetime):
            # Convert to UTC and add Z suffix
            if obj.tzinfo is None:
                # Assume naive datetime is UTC
                return obj.isoformat() + 'Z'
            else:
                utc_dt = obj.astimezone(timezone.utc)
                return utc_dt.strftime('%Y-%m-%dT%H:%M:%SZ')
        if hasattr(obj, '__dataclass_fields__'):
            return asdict(obj)
        if hasattr(obj, '__dict__'):
            return obj.__dict__
        return super().default(obj)


def utc_now() -> str:
    """Get current UTC timestamp as ISO8601 string with Z suffix."""
    return datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


def output(data: Any, json_mode: bool, success: bool = True):
    """Output data in human or JSON format."""
    if json_mode:
        result = {
            'success': success,
            'data': data,
            'timestamp': utc_now()
        }
        print(json.dumps(result, cls=JSONEncoder, indent=2))
    else:
        if isinstance(data, str):
            print(data)
        elif isinstance(data, list):
            for item in data:
                print(item)
        elif isinstance(data, dict):
            for k, v in data.items():
                print(f"{k}: {v}")


def error(message: str, json_mode: bool):
    """Output error in human or JSON format."""
    if json_mode:
        result = {
            'success': False,
            'error': message,
            'timestamp': utc_now()
        }
        print(json.dumps(result, indent=2))
    else:
        print(f"Error: {message}", file=sys.stderr)
    sys.exit(1)


# =============================================================================
# Commands
# =============================================================================

def list_pending(db: SpeakerDatabase, json_mode: bool):
    """Show pending name suggestions."""
    pending = db.get_pending_suggestions()
    
    if json_mode:
        # Convert to dicts, omit status field (always 'pending')
        data = []
        for p in pending:
            d = asdict(p)
            del d['status']  # Redundant since endpoint only returns pending
            data.append(d)
        output(data, json_mode)
    else:
        if not pending:
            print("No pending name suggestions.")
            return
        
        print(f"\n{'ID':<36} {'Speaker':<36} {'Suggested Name':<20} {'Source':<12} {'Confidence'}")
        print("-" * 120)
        for p in pending:
            print(f"{p.suggestion_id:<36} {p.speaker_id:<36} {p.suggested_name:<20} {p.source:<12} {p.confidence:.2f}")
            if p.context:
                # Truncate and clean context for display
                context = p.context.replace('\n', ' ')[:80]
                print(f"   Context: {context}...")
        print(f"\nTotal: {len(pending)} pending suggestions")
        print("\nUse 'confirm <id>' or 'reject <id>' to process suggestions.")


def confirm_name(db: SpeakerDatabase, suggestion_id: str, json_mode: bool):
    """Accept a name suggestion."""
    try:
        # Get suggestion info before confirming
        pending = db.get_pending_suggestions()
        suggestion = next((p for p in pending if p.suggestion_id == suggestion_id), None)
        if not suggestion:
            error(f"Suggestion {suggestion_id} not found", json_mode)
        
        db.confirm_name(suggestion_id)
        
        if json_mode:
            output({
                'confirmed': True,
                'suggestion_id': suggestion_id,
                'speaker_id': suggestion.speaker_id,
                'name': suggestion.suggested_name
            }, json_mode)
        else:
            print(f"✓ Confirmed suggestion {suggestion_id}")
            print(f"  Speaker {suggestion.speaker_id} is now named '{suggestion.suggested_name}'")
    except ValueError as e:
        error(str(e), json_mode)


def reject_name(db: SpeakerDatabase, suggestion_id: str, json_mode: bool):
    """Reject a name suggestion."""
    try:
        db.reject_name(suggestion_id)
        
        if json_mode:
            output({
                'rejected': True,
                'suggestion_id': suggestion_id
            }, json_mode)
        else:
            print(f"✗ Rejected suggestion {suggestion_id}")
    except ValueError as e:
        error(str(e), json_mode)


def list_speakers(db: SpeakerDatabase, json_mode: bool, include_unnamed: bool = True):
    """Show all known speakers."""
    speakers = db.get_all_speakers(include_unnamed=include_unnamed)
    
    if json_mode:
        output([asdict(s) for s in speakers], json_mode)
    else:
        if not speakers:
            print("No speakers in database.")
            return
        
        print(f"\n{'ID':<36} {'Name':<25} {'Embeddings':<12} {'Last Seen'}")
        print("-" * 100)
        for s in speakers:
            name = s.name or "(unnamed)"
            last_seen = s.last_seen_at[:19] if s.last_seen_at else "never"
            print(f"{s.speaker_id:<36} {name:<25} {s.embedding_count:<12} {last_seen}")
        print(f"\nTotal: {len(speakers)} speakers")


def get_speaker(db: SpeakerDatabase, speaker_id: str, json_mode: bool):
    """Show details for a specific speaker."""
    speaker = db.get_speaker(speaker_id)
    if not speaker:
        error(f"Speaker {speaker_id} not found", json_mode)
    
    # Get related data
    terms = db.get_speaker_terms([speaker_id], limit=50)
    embeddings = db.get_embeddings(speaker_id)
    pending = [p for p in db.get_pending_suggestions() if p.speaker_id == speaker_id]
    
    if json_mode:
        # Convert pending to dicts without status field
        pending_data = []
        for p in pending:
            d = asdict(p)
            del d['status']
            pending_data.append(d)
        
        output({
            'speaker': asdict(speaker),
            'terms': [{'text': t.text, 'category': t.category, 'frequency': 1} for t in terms],
            'embeddings': embeddings,
            'pending_names': pending_data
        }, json_mode)
    else:
        print(f"\nSpeaker: {speaker.speaker_id}")
        print("-" * 50)
        print(f"  Name:            {speaker.name or '(unnamed)'}")
        print(f"  Name confidence: {speaker.name_confidence or 'N/A'}")
        print(f"  Email:           {speaker.email or 'N/A'}")
        print(f"  Embedding count: {speaker.embedding_count}")
        print(f"  Created:         {speaker.created_at}")
        print(f"  Last seen:       {speaker.last_seen_at}")
        
        if terms:
            print(f"\n  Top terms ({len(terms)} shown):")
            for t in terms[:10]:
                print(f"    - {t.text} ({t.category}, conf={t.confidence:.2f})")
        
        if embeddings:
            print(f"\n  Embeddings ({len(embeddings)} total):")
            for e in embeddings[:5]:
                source = e['audio_source'] or 'unknown'
                print(f"    - {e['embedding_id'][:12]}... from {source}")
            if len(embeddings) > 5:
                print(f"    ... and {len(embeddings) - 5} more")
        
        if pending:
            print(f"\n  Pending name suggestions:")
            for p in pending:
                print(f"    - '{p.suggested_name}' (from {p.source}, conf={p.confidence:.2f})")
                print(f"      ID: {p.suggestion_id}")


def rename_speaker(db: SpeakerDatabase, speaker_id: str, name: str, json_mode: bool):
    """Manually set a speaker's name."""
    try:
        db.set_speaker_name(speaker_id, name, confidence=1.0, source='manual')
        
        if json_mode:
            output({
                'renamed': True,
                'speaker_id': speaker_id,
                'name': name
            }, json_mode)
        else:
            print(f"✓ Renamed speaker {speaker_id} to '{name}'")
    except ValueError as e:
        error(str(e), json_mode)


def merge_speakers(db: SpeakerDatabase, keep_id: str, merge_id: str, json_mode: bool, force: bool = False):
    """Merge two speaker entries."""
    # Verify both exist
    keep = db.get_speaker(keep_id)
    merge = db.get_speaker(merge_id)
    
    if not keep:
        error(f"Speaker {keep_id} not found", json_mode)
    if not merge:
        error(f"Speaker {merge_id} not found", json_mode)
    
    if not force and not json_mode:
        keep_name = keep.name or keep_id
        merge_name = merge.name or merge_id
        confirm = input(f"Merge '{merge_name}' into '{keep_name}'? This cannot be undone. [y/N] ")
        if confirm.lower() != 'y':
            print("Cancelled.")
            return
    
    # Create backup before destructive operation
    backup_path = db.backup()
    
    db.merge_speakers(keep_id, merge_id)
    
    if json_mode:
        output({
            'merged': True,
            'kept_speaker_id': keep_id,
            'merged_speaker_id': merge_id,
            'backup_path': backup_path
        }, json_mode)
    else:
        print(f"✓ Merged {merge_id} into {keep_id}")
        print(f"  Backup created: {backup_path}")


def split_speaker(db: SpeakerDatabase, speaker_id: str, embedding_ids: list[str], json_mode: bool, force: bool = False):
    """Split a speaker by moving some embeddings to a new speaker."""
    speaker = db.get_speaker(speaker_id)
    if not speaker:
        error(f"Speaker {speaker_id} not found", json_mode)
    
    if not force and not json_mode:
        confirm = input(f"Split {len(embedding_ids)} embeddings from speaker {speaker_id}? [y/N] ")
        if confirm.lower() != 'y':
            print("Cancelled.")
            return
    
    # Create backup before destructive operation
    backup_path = db.backup()
    
    try:
        new_speaker_id = db.split_speaker(speaker_id, embedding_ids)
        
        if json_mode:
            output({
                'split': True,
                'original_speaker_id': speaker_id,
                'new_speaker_id': new_speaker_id,
                'embeddings_moved': len(embedding_ids),
                'backup_path': backup_path
            }, json_mode)
        else:
            print(f"✓ Split speaker {speaker_id}")
            print(f"  Created new speaker: {new_speaker_id}")
            print(f"  Moved {len(embedding_ids)} embeddings")
            print(f"  Backup created: {backup_path}")
    except ValueError as e:
        error(str(e), json_mode)


def delete_speaker(db: SpeakerDatabase, speaker_id: str, json_mode: bool, force: bool = False):
    """Delete a speaker."""
    speaker = db.get_speaker(speaker_id)
    if not speaker:
        error(f"Speaker {speaker_id} not found", json_mode)
    
    if not force and not json_mode:
        name = speaker.name or "(unnamed)"
        confirm = input(f"Delete speaker '{name}' ({speaker_id})? This cannot be undone. [y/N] ")
        if confirm.lower() != 'y':
            print("Cancelled.")
            return
    
    # Create backup before destructive operation
    backup_path = db.backup()
    
    db.delete_speaker(speaker_id)
    
    if json_mode:
        output({
            'deleted': True,
            'speaker_id': speaker_id,
            'backup_path': backup_path
        }, json_mode)
    else:
        print(f"✓ Deleted speaker {speaker_id}")
        print(f"  Backup created: {backup_path}")


def show_stats(db: SpeakerDatabase, json_mode: bool):
    """Show database statistics."""
    stats = db.get_stats()
    
    if json_mode:
        output(stats, json_mode)
    else:
        print(f"\nSpeaker Database Statistics")
        print("-" * 40)
        print(f"  Total speakers:           {stats['speaker_count']}")
        print(f"  Named speakers:           {stats['named_speaker_count']}")
        print(f"  Total embeddings:         {stats['embedding_count']}")
        print(f"  Cached prompts:           {stats['cache_count']}")
        print(f"  Speaker terms:            {stats['term_count']}")
        print(f"  Pending name suggestions: {stats['pending_count']}")
        print(f"  Database size:            {stats['db_size_mb']:.2f} MB")


def run_cleanup(db: SpeakerDatabase, json_mode: bool):
    """Run maintenance cleanup."""
    from prompt_generator import cleanup_database
    
    if not json_mode:
        print("Running database cleanup...")
    
    # Create backup before cleanup
    backup_path = db.backup()
    
    # Run cleanup and capture stats
    stats_before = db.get_stats()
    cleanup_database(db)
    stats_after = db.get_stats()
    
    # Calculate what was cleaned
    stale_removed = stats_before['speaker_count'] - stats_after['speaker_count']
    cache_pruned = stats_before['cache_count'] - stats_after['cache_count']
    
    if json_mode:
        output({
            'backup_path': backup_path,
            'stale_speakers_removed': max(0, stale_removed),
            'orphaned_embeddings_removed': 0,  # cleanup_database doesn't track this separately
            'cache_entries_pruned': max(0, cache_pruned)
        }, json_mode)
    else:
        print(f"✓ Cleanup completed")
        print(f"  Backup created: {backup_path}")
        if stale_removed > 0:
            print(f"  Removed {stale_removed} stale speakers")
        if cache_pruned > 0:
            print(f"  Pruned {cache_pruned} cache entries")


def check_integrity(db: SpeakerDatabase, json_mode: bool):
    """Check database integrity."""
    issues = db.check_integrity()
    
    if json_mode:
        output({
            'healthy': len(issues) == 0,
            'issues': issues
        }, json_mode)
    else:
        if not issues:
            print("✅ Database integrity check passed")
        else:
            print(f"⚠️  Found {len(issues)} issues:")
            for issue in issues:
                print(f"  - {issue}")
            sys.exit(1)


def create_backup(db: SpeakerDatabase, json_mode: bool):
    """Create a database backup."""
    backup_path = db.backup()
    
    if json_mode:
        output({
            'backup_path': backup_path
        }, json_mode)
    else:
        print(f"✓ Backup created: {backup_path}")


# =============================================================================
# Contact Commands
# =============================================================================

def list_contacts(db: SpeakerDatabase, json_mode: bool):
    """Show all contacts."""
    contacts = db.get_all_contacts()
    
    if json_mode:
        output([asdict(c) for c in contacts], json_mode)
    else:
        if not contacts:
            print("No contacts in database.")
            return
        
        print(f"\n{'Email':<35} {'Display Name':<25} {'Preferred':<15} {'Source':<10}")
        print("-" * 90)
        for c in contacts:
            display = c.display_name or "(none)"
            preferred = c.preferred_name or ""
            print(f"{c.email:<35} {display:<25} {preferred:<15} {c.source:<10}")
        print(f"\nTotal: {len(contacts)} contacts")


def add_contact(db: SpeakerDatabase, email: str, json_mode: bool,
               display_name: str = None, preferred_name: str = None,
               pronunciation: str = None, aliases: list[str] = None,
               role: str = None, team: str = None, source: str = 'manual'):
    """Add or update a contact."""
    db.upsert_contact(
        email=email,
        display_name=display_name,
        preferred_name=preferred_name,
        pronunciation=pronunciation,
        aliases=aliases,
        role=role,
        team=team,
        source=source
    )
    
    if json_mode:
        output({
            'upserted': True,
            'email': email,
            'source': source
        }, json_mode)
    else:
        print(f"\u2713 Contact {email} added/updated (source={source})")


def delete_contact(db: SpeakerDatabase, email: str, json_mode: bool):
    """Delete a contact."""
    try:
        db.delete_contact(email)
        if json_mode:
            output({'deleted': True, 'email': email}, json_mode)
        else:
            print(f"\u2713 Deleted contact {email}")
    except ValueError as e:
        error(str(e), json_mode)


def associate_email(db: SpeakerDatabase, speaker_id: str, email: str, json_mode: bool):
    """Associate an email address with a speaker."""
    try:
        db.associate_email(speaker_id, email)
        
        if json_mode:
            output({
                'associated': True,
                'speaker_id': speaker_id,
                'email': email
            }, json_mode)
        else:
            print(f"\u2713 Associated email {email} with speaker {speaker_id}")
    except ValueError as e:
        error(str(e), json_mode)


def export_speaker(db: SpeakerDatabase, speaker_id: str, json_mode: bool, output_path: Optional[str] = None):
    """Export speaker data (for GDPR compliance)."""
    try:
        data = db.export_speaker_data(speaker_id)
    except ValueError as e:
        error(str(e), json_mode)
    
    if json_mode:
        output(data, json_mode)
    elif output_path:
        with open(output_path, 'w') as f:
            json.dump(data, f, indent=2, default=str)
        print(f"✓ Exported to {output_path}")
    else:
        print(json.dumps(data, indent=2, default=str))


# =============================================================================
# Main
# =============================================================================

def main():
    parser = argparse.ArgumentParser(
        description="Manage the speaker database for smart prompt generation",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  speaker_cli.py list-pending              Show pending name suggestions
  speaker_cli.py confirm abc123...         Accept a name suggestion
  speaker_cli.py list-speakers             Show all speakers
  speaker_cli.py rename <id> "John Smith"  Set speaker name manually
  speaker_cli.py stats                     Show database statistics
  speaker_cli.py --json list-speakers      Output as JSON (for programmatic use)
        """
    )
    parser.add_argument(
        '--json',
        action='store_true',
        help="Output in JSON format (for programmatic access)"
    )
    parser.add_argument(
        '--db', 
        default=str(DEFAULT_DB_PATH), 
        help=f"Database path (default: {DEFAULT_DB_PATH})"
    )
    
    subparsers = parser.add_subparsers(dest='command', required=True)
    
    # list-pending
    subparsers.add_parser('list-pending', help="Show pending name suggestions")
    
    # confirm
    confirm_parser = subparsers.add_parser('confirm', help="Confirm a name suggestion")
    confirm_parser.add_argument('suggestion_id', help="Suggestion ID to confirm")
    
    # reject
    reject_parser = subparsers.add_parser('reject', help="Reject a name suggestion")
    reject_parser.add_argument('suggestion_id', help="Suggestion ID to reject")
    
    # list-speakers
    list_parser = subparsers.add_parser('list-speakers', help="Show all speakers")
    list_parser.add_argument('--named-only', action='store_true', help="Only show named speakers")
    
    # get-speaker
    get_parser = subparsers.add_parser('get-speaker', help="Get speaker details")
    get_parser.add_argument('speaker_id', help="Speaker ID to show")
    
    # rename
    rename_parser = subparsers.add_parser('rename', help="Manually set speaker name")
    rename_parser.add_argument('speaker_id', help="Speaker ID to rename")
    rename_parser.add_argument('name', help="New name for the speaker")
    
    # merge
    merge_parser = subparsers.add_parser('merge', help="Merge duplicate speakers")
    merge_parser.add_argument('keep_id', help="Speaker ID to keep")
    merge_parser.add_argument('merge_id', help="Speaker ID to merge into keep_id")
    merge_parser.add_argument('--force', '-f', action='store_true', help="Skip confirmation")
    
    # split
    split_parser = subparsers.add_parser('split', help="Split incorrectly merged speaker")
    split_parser.add_argument('speaker_id', help="Speaker to split")
    split_parser.add_argument('embedding_ids', nargs='+', help="Embedding IDs to move to new speaker")
    split_parser.add_argument('--force', '-f', action='store_true', help="Skip confirmation")
    
    # delete
    delete_parser = subparsers.add_parser('delete', help="Delete a speaker")
    delete_parser.add_argument('speaker_id', help="Speaker ID to delete")
    delete_parser.add_argument('--force', '-f', action='store_true', help="Skip confirmation")
    
    # stats
    subparsers.add_parser('stats', help="Show database statistics")
    
    # cleanup
    subparsers.add_parser('cleanup', help="Run maintenance cleanup")
    
    # check
    subparsers.add_parser('check', help="Check database integrity")
    
    # backup
    subparsers.add_parser('backup', help="Create a backup")
    
    # export
    export_parser = subparsers.add_parser('export', help="Export speaker data (GDPR)")
    export_parser.add_argument('speaker_id', help="Speaker ID to export")
    export_parser.add_argument('--output', '-o', help="Output file path (default: stdout)")
    
    # list-contacts
    subparsers.add_parser('list-contacts', help="Show all contacts")
    
    # add-contact
    add_contact_parser = subparsers.add_parser('add-contact', help="Add or update a contact")
    add_contact_parser.add_argument('email', help="Contact email (primary key)")
    add_contact_parser.add_argument('--name', dest='display_name', help="Full display name")
    add_contact_parser.add_argument('--preferred-name', help="Preferred name / nickname")
    add_contact_parser.add_argument('--pronunciation', help="Phonetic pronunciation guide")
    add_contact_parser.add_argument('--aliases', nargs='*', help="Alias/misspelling variants")
    add_contact_parser.add_argument('--role', help="Job title")
    add_contact_parser.add_argument('--team', help="Department/team")
    add_contact_parser.add_argument('--source', default='manual', choices=['manual', 'calendar', 'auto'],
                                   help="Source of the contact (default: manual)")
    
    # update-contact (alias for add-contact)
    update_contact_parser = subparsers.add_parser('update-contact', help="Update an existing contact")
    update_contact_parser.add_argument('email', help="Contact email")
    update_contact_parser.add_argument('--name', dest='display_name', help="Full display name")
    update_contact_parser.add_argument('--preferred-name', help="Preferred name / nickname")
    update_contact_parser.add_argument('--pronunciation', help="Phonetic pronunciation guide")
    update_contact_parser.add_argument('--aliases', nargs='*', help="Alias/misspelling variants")
    update_contact_parser.add_argument('--role', help="Job title")
    update_contact_parser.add_argument('--team', help="Department/team")
    
    # delete-contact
    del_contact_parser = subparsers.add_parser('delete-contact', help="Delete a contact")
    del_contact_parser.add_argument('email', help="Contact email to delete")
    
    # associate-email
    assoc_parser = subparsers.add_parser('associate-email', help="Associate an email with a speaker")
    assoc_parser.add_argument('speaker_id', help="Speaker ID")
    assoc_parser.add_argument('email', help="Email address to associate")
    
    # Also support legacy 'show' command as alias for 'get-speaker'
    show_parser = subparsers.add_parser('show', help="Show details for a speaker (alias for get-speaker)")
    show_parser.add_argument('speaker_id', help="Speaker ID to show")
    
    args = parser.parse_args()
    json_mode = args.json
    
    # Check database exists for most commands
    db_path = Path(args.db)
    if not db_path.exists() and args.command not in ('stats', 'check'):
        error(f"Database not found: {args.db}\n\nThe speaker database is created automatically when Smart Prompts processes its first meeting.", json_mode)
    
    # Initialize database
    try:
        db = SpeakerDatabase(args.db)
    except SpeakerDBError as e:
        error(f"Database error: {e}", json_mode)
    
    try:
        if args.command == 'list-pending':
            list_pending(db, json_mode)
        elif args.command == 'confirm':
            confirm_name(db, args.suggestion_id, json_mode)
        elif args.command == 'reject':
            reject_name(db, args.suggestion_id, json_mode)
        elif args.command == 'list-speakers':
            list_speakers(db, json_mode, include_unnamed=not args.named_only)
        elif args.command in ('get-speaker', 'show'):
            get_speaker(db, args.speaker_id, json_mode)
        elif args.command == 'rename':
            rename_speaker(db, args.speaker_id, args.name, json_mode)
        elif args.command == 'merge':
            merge_speakers(db, args.keep_id, args.merge_id, json_mode, force=args.force)
        elif args.command == 'split':
            split_speaker(db, args.speaker_id, args.embedding_ids, json_mode, force=args.force)
        elif args.command == 'delete':
            delete_speaker(db, args.speaker_id, json_mode, force=args.force)
        elif args.command == 'stats':
            show_stats(db, json_mode)
        elif args.command == 'cleanup':
            run_cleanup(db, json_mode)
        elif args.command == 'check':
            check_integrity(db, json_mode)
        elif args.command == 'backup':
            create_backup(db, json_mode)
        elif args.command == 'list-contacts':
            list_contacts(db, json_mode)
        elif args.command in ('add-contact', 'update-contact'):
            add_contact(
                db, args.email, json_mode,
                display_name=args.display_name,
                preferred_name=args.preferred_name,
                pronunciation=args.pronunciation,
                aliases=args.aliases,
                role=args.role,
                team=getattr(args, 'team', None),
                source=getattr(args, 'source', 'manual')
            )
        elif args.command == 'delete-contact':
            delete_contact(db, args.email, json_mode)
        elif args.command == 'associate-email':
            associate_email(db, args.speaker_id, args.email, json_mode)
        elif args.command == 'export':
            export_speaker(db, args.speaker_id, json_mode, output_path=args.output)
    except Exception as e:
        error(f"Unexpected error: {e}", json_mode)
    finally:
        db.close()


if __name__ == '__main__':
    main()
