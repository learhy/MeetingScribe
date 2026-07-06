#!/usr/bin/env python3
"""
MeetingScribe Ollama Prototyping Tool

Rapidly iterate on Ollama models and prompts without live meetings or cloud API calls.
This tool transcribes recordings and generates notes locally.

SCOPE: This is a prototyping/tuning tool, not a test harness. Findings should be
validated against the production Swift implementation.

Usage:
    ./test-processing.py /path/to/recording.wav [options]
    ./test-processing.py --batch ~/Documents/MeetingScribe/recordings/ --model llama3.2
    ./test-processing.py /path/to/recording.wav --glossary glossary.example.json

Options:
    --model MODEL           Ollama model to use (default: from config)
    --prompt-file FILE      Path to custom system prompt (default: from config)
    --glossary FILE         Path to glossary JSON file for term correction
    --show-corrections     Show which glossary terms appear in output
    --output DIR            Output directory (default: ~/Documents/MeetingScribe/notes/)
    --dry-run              Transcription only, skip notes generation
    --verbose              Detailed timing and debug output
    --batch DIR            Process all .wav files in directory
    --help                 Show this help message
"""

import sys
import json
import os
import argparse
import subprocess
import time
import requests
from pathlib import Path
from datetime import datetime
from typing import Optional, Dict, Any, List, Set
import signal
import re
import difflib


class GlossaryEntry:
    """A single glossary entry with term metadata."""
    
    def __init__(self, term: str, pronunciation: Optional[str] = None, 
                 context: Optional[str] = None, aliases: Optional[list] = None):
        self.term = term
        self.pronunciation = pronunciation
        self.context = context
        self.aliases = aliases or []
    
    def format(self) -> str:
        """Format entry for prompt injection (matches Swift implementation)."""
        parts = [self.term]
        details = []
        if self.pronunciation:
            details.append(f"pronunciation: {self.pronunciation}")
        if self.context:
            details.append(f"context: {self.context}")
        if self.aliases:
            details.append(f"aliases: {', '.join(self.aliases)}")
        if details:
            parts.append(f"({'; '.join(details)})")
        return ' '.join(parts)


class Glossary:
    """Manages glossary entries for term correction."""
    
    def __init__(self, enabled: bool = False, entries: Optional[list] = None, max_size: int = 1000):
        self.enabled = enabled
        self.entries: list[GlossaryEntry] = entries or []
        self.max_size = max_size
    
    @classmethod
    def from_file(cls, path: str) -> 'Glossary':
        """Load glossary from JSON file."""
        path = os.path.expanduser(path)
        
        if not os.path.exists(path):
            raise FileNotFoundError(f"Glossary file not found: {path}")
        
        with open(path, 'r') as f:
            data = json.load(f)
        
        # Validate structure
        if not isinstance(data, dict):
            raise ValueError("Glossary must be a JSON object")
        
        enabled = data.get('enabled', True)
        max_size = data.get('maxSize', 1000)
        
        entries = []
        for entry_data in data.get('entries', []):
            if not isinstance(entry_data, dict):
                raise ValueError("Each glossary entry must be a JSON object")
            if 'term' not in entry_data:
                raise ValueError("Each glossary entry must have a 'term' field")
            
            # Validate term length (matches Swift validation)
            term = entry_data['term']
            if len(term) > 100:
                raise ValueError(f"Term '{term[:20]}...' exceeds max length of 100")
            
            context = entry_data.get('context')
            if context and len(context) > 200:
                raise ValueError(f"Context for '{term}' exceeds max length of 200")
            
            pronunciation = entry_data.get('pronunciation')
            if pronunciation and len(pronunciation) > 100:
                raise ValueError(f"Pronunciation for '{term}' exceeds max length of 100")
            
            entries.append(GlossaryEntry(
                term=term,
                pronunciation=pronunciation,
                context=context,
                aliases=entry_data.get('aliases')
            ))
        
        if len(entries) > max_size:
            raise ValueError(f"Glossary has {len(entries)} entries, exceeds max of {max_size}")
        
        return cls(enabled=enabled, entries=entries, max_size=max_size)
    
    def format_for_prompt(self) -> str:
        """Format glossary for injection into system prompt (matches Swift implementation)."""
        if not self.enabled or not self.entries:
            return ""
        
        formatted_entries = [entry.format() for entry in self.entries]
        return "\n\n## KNOWN TERMS (correct to these when phonetically similar)\n" + " | ".join(formatted_entries)
    
    def __len__(self) -> int:
        return len(self.entries)
    
    def get_all_terms(self) -> Set[str]:
        """Get all terms and aliases as a set for matching."""
        terms = set()
        for entry in self.entries:
            terms.add(entry.term.lower())
            for alias in entry.aliases:
                terms.add(alias.lower())
        return terms
    
    def find_matches_in_text(self, text: str) -> Dict[str, int]:
        """Find glossary terms that appear in text with counts."""
        matches = {}
        text_lower = text.lower()
        
        for entry in self.entries:
            # Check main term
            count = len(re.findall(r'\b' + re.escape(entry.term.lower()) + r'\b', text_lower))
            if count > 0:
                matches[entry.term] = count
            
            # Check aliases
            for alias in entry.aliases:
                alias_count = len(re.findall(r'\b' + re.escape(alias.lower()) + r'\b', text_lower))
                if alias_count > 0:
                    # Track under alias name with reference to main term
                    matches[f"{alias} → {entry.term}"] = alias_count
        
        return matches


class Config:
    """Load and manage MeetingScribe configuration."""
    
    def __init__(self, config_path: Optional[str] = None):
        if config_path is None:
            config_path = os.path.expanduser("~/.meetingscribe/config.json")
        
        self.path = config_path
        self.data = self._load_config()
    
    def _load_config(self) -> Dict[str, Any]:
        """Load config from JSON file."""
        if not os.path.exists(self.path):
            raise FileNotFoundError(f"Config file not found: {self.path}")
        
        with open(self.path, 'r') as f:
            return json.load(f)
    
    def expand_path(self, path: str) -> str:
        """Expand ~ and environment variables in path."""
        return os.path.expanduser(os.path.expandvars(path))
    
    @property
    def whisper_binary(self) -> str:
        """Path to whisper.cpp binary."""
        return self.expand_path(self.data['transcription']['local']['whisperBinaryPath'])
    
    @property
    def whisper_model(self) -> str:
        """Path to whisper.cpp model."""
        return self.expand_path(self.data['transcription']['local']['modelPath'])
    
    @property
    def ollama_endpoint(self) -> str:
        """Ollama API endpoint."""
        return self.data['notes']['llm']['ollama']['endpoint']
    
    @property
    def ollama_model(self) -> str:
        """Default Ollama model."""
        return self.data['notes']['llm']['ollama']['model']
    
    @property
    def system_prompt_file(self) -> str:
        """Path to system prompt file."""
        return self.expand_path(self.data['notes']['llm']['systemPromptFile'])
    
    @property
    def output_directory(self) -> str:
        """Default output directory for notes."""
        return self.expand_path(self.data['notes']['bear']['fallbackDirectory'])


class TranscriptionEngine:
    """Handle audio transcription using whisper.cpp."""
    
    def __init__(self, config: Config, verbose: bool = False):
        self.config = config
        self.verbose = verbose
    
    def transcribe(self, audio_file: str) -> tuple[str, float]:
        """
        Transcribe audio file using whisper.cpp.
        
        Args:
            audio_file: Path to audio file
            
        Returns:
            Tuple of (transcript_text, duration_seconds)
        """
        audio_file = os.path.expanduser(audio_file)
        
        if not os.path.exists(audio_file):
            raise FileNotFoundError(f"Audio file not found: {audio_file}")
        
        if not os.path.exists(self.config.whisper_binary):
            raise FileNotFoundError(
                f"whisper.cpp binary not found at: {self.config.whisper_binary}\n"
                f"Expected location: ~/My Drive/software_projects/whisper.cpp/main"
            )
        
        if not os.path.exists(self.config.whisper_model):
            raise FileNotFoundError(
                f"whisper.cpp model not found at: {self.config.whisper_model}"
            )
        
        if self.verbose:
            print(f"[Transcription] Binary: {self.config.whisper_binary}")
            print(f"[Transcription] Model: {self.config.whisper_model}")
            print(f"[Transcription] Audio: {audio_file}")
        
        # Resample audio to 16kHz (required by whisper.cpp)
        print("[Transcription] Resampling audio to 16kHz...")
        temp_dir = "/tmp"
        resampled_file = os.path.join(temp_dir, f"resampled_{int(time.time())}.wav")
        
        try:
            self._resample_audio(audio_file, resampled_file)
        except Exception as e:
            raise RuntimeError(f"Failed to resample audio: {e}")
        
        # Run transcription
        print("[Transcription] Running whisper.cpp...")
        start_time = time.time()
        
        output_prefix = os.path.join(temp_dir, f"transcript_{int(time.time())}")
        
        cmd = [
            self.config.whisper_binary,
            "-m", self.config.whisper_model,
            "-f", resampled_file,
            "-otxt",
            "-of", output_prefix,
            "--no-timestamps",
            "-t", "4"
        ]
        
        try:
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=3600  # 1 hour timeout
            )
            
            duration = time.time() - start_time
            
            if result.returncode != 0:
                error_msg = result.stderr or result.stdout or "Unknown error"
                raise RuntimeError(f"whisper.cpp failed: {error_msg}")
            
            # Read transcript
            output_file = f"{output_prefix}.txt"
            if not os.path.exists(output_file):
                raise RuntimeError(f"Transcript file not created: {output_file}")
            
            with open(output_file, 'r') as f:
                transcript = f.read().strip()
            
            # Cleanup
            os.remove(output_file)
            os.remove(resampled_file)
            
            if not transcript:
                raise RuntimeError("Transcription produced empty result")
            
            print(f"[Transcription] Complete ({duration:.1f}s)")
            return transcript, duration
            
        except subprocess.TimeoutExpired:
            raise RuntimeError("Transcription timed out (1 hour)")
        except Exception as e:
            # Cleanup on error
            if os.path.exists(resampled_file):
                os.remove(resampled_file)
            raise
    
    def _resample_audio(self, input_file: str, output_file: str) -> None:
        """Resample audio to 16kHz using ffmpeg."""
        cmd = [
            "ffmpeg",
            "-i", input_file,
            "-ar", "16000",
            "-ac", "1",
            "-c:a", "pcm_s16le",
            "-y", output_file
        ]
        
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            stdin=subprocess.DEVNULL,
            timeout=3600
        )
        
        if result.returncode != 0:
            raise RuntimeError(f"ffmpeg resampling failed: {result.stderr}")


class NotesGenerator:
    """Generate meeting notes using Ollama."""
    
    def __init__(self, config: Config, verbose: bool = False, glossary: Optional[Glossary] = None):
        self.config = config
        self.verbose = verbose
        self.glossary = glossary
        self.system_prompt = self._load_prompt()
    
    def _load_prompt(self) -> str:
        """Load system prompt from file or use default."""
        prompt_file = self.config.system_prompt_file
        
        if os.path.exists(prompt_file):
            with open(prompt_file, 'r') as f:
                return f.read().strip()
        
        return self._default_prompt()
    
    def _default_prompt(self) -> str:
        """Default system prompt for notes generation."""
        base_prompt = """You are a professional meeting notes assistant. Your task is to generate clear, concise, and well-structured meeting notes from transcripts.

Guidelines:
1. Start with a brief summary (2-3 sentences) of the meeting's purpose and outcome
2. Extract key discussion points as bullet points
3. Identify action items with owners (if mentioned)
4. List any decisions made
5. Note any follow-up meetings or deadlines
6. Use clear, professional language
7. Format output in Markdown

CRITICAL: Generate exactly ONE cohesive document with the following structure:
- Summary (at the top)
- Key Points (all points in ONE section)
- Action Items (if any - in ONE section)
- Decisions (if any - in ONE section)
- Next Steps (if any - in ONE section)

DO NOT create multiple sections or repeat headers. Process the entire transcript and consolidate all information into a single, unified document.

Be concise but comprehensive. Focus on actionable information."""
        
        # Inject glossary context if available
        if self.glossary and self.glossary.enabled:
            glossary_context = self.glossary.format_for_prompt()
            if glossary_context:
                base_prompt += glossary_context
        
        return base_prompt
    
    def generate(self, transcript: str, model: Optional[str] = None) -> tuple[str, float, int]:
        """
        Generate notes using Ollama.
        
        Args:
            transcript: Meeting transcript text
            model: Optional model override (default: from config)
            
        Returns:
            Tuple of (notes_text, duration_seconds, token_count)
        """
        model = model or self.config.ollama_model
        
        if self.verbose:
            print(f"[Notes] Model: {model}")
            print(f"[Notes] Endpoint: {self.config.ollama_endpoint}")
        
        # Check Ollama connectivity
        self._check_ollama()
        
        # Build prompt
        prompt = f"{self.system_prompt}\n\nGenerate meeting notes from this transcript:\n\n{transcript}"
        
        # Call Ollama
        print(f"[Notes] Generating notes with {model}...")
        start_time = time.time()
        
        try:
            response = requests.post(
                f"{self.config.ollama_endpoint}/api/generate",
                json={
                    "model": model,
                    "prompt": prompt,
                    "stream": False
                },
                timeout=300  # 5 minute timeout
            )
            
            if response.status_code == 404:
                raise RuntimeError(
                    f"Model '{model}' not found in Ollama.\n"
                    f"Pull it with: ollama pull {model}"
                )
            
            if response.status_code != 200:
                raise RuntimeError(
                    f"Ollama error ({response.status_code}): {response.text}"
                )
            
            data = response.json()
            notes = data.get('response', '').strip()
            token_count = len(notes.split())  # Rough estimate
            duration = time.time() - start_time
            
            if not notes:
                raise RuntimeError("Notes generation produced empty result")
            
            print(f"[Notes] Complete ({duration:.1f}s, ~{token_count} tokens)")
            return notes, duration, token_count
            
        except requests.ConnectionError:
            raise RuntimeError(
                f"Cannot connect to Ollama at {self.config.ollama_endpoint}\n"
                f"Start Ollama with: ollama serve"
            )
        except requests.Timeout:
            raise RuntimeError("Notes generation timed out (5 minutes)")
        except Exception as e:
            raise RuntimeError(f"Notes generation failed: {e}")
    
    def _check_ollama(self) -> None:
        """Verify Ollama is running and accessible."""
        try:
            response = requests.get(
                f"{self.config.ollama_endpoint}/api/tags",
                timeout=5
            )
            if response.status_code != 200:
                raise RuntimeError(f"Ollama returned error: {response.status_code}")
        except requests.ConnectionError:
            raise RuntimeError(
                f"Cannot connect to Ollama at {self.config.ollama_endpoint}\n"
                f"Start Ollama with: ollama serve"
            )


class NotesTemplate:
    """Render final notes output."""
    
    @staticmethod
    def render(notes: str, metadata: Dict[str, Any], transcript: Optional[str] = None, 
               system_prompt: Optional[str] = None, glossary: Optional[Glossary] = None) -> str:
        """
        Render notes with metadata, system prompt, glossary info, and transcript.
        
        Args:
            notes: Generated notes content
            metadata: Dict with 'timestamp', 'recording', 'duration', 'model'
            transcript: Optional full meeting transcript to append
            system_prompt: Optional system prompt used for generation
            glossary: Optional glossary used for term correction
            
        Returns:
            Rendered markdown output
        """
        timestamp = metadata.get('timestamp', '')
        recording = metadata.get('recording', '')
        duration = metadata.get('duration', '')
        model = metadata.get('model', '')
        
        # Build glossary status line
        glossary_status = "Disabled"
        if glossary and glossary.enabled:
            glossary_status = f"Enabled ({len(glossary)} terms)"
        
        header = f"""# Meeting Notes
Generated: {timestamp}
Recording: {recording}
Duration: {duration}
LLM Model: {model}
Glossary: {glossary_status}

---
"""
        
        # Add system prompt if provided
        if system_prompt:
            header += f"""\n## System Prompt\n```\n{system_prompt}\n```\n
---

"""
        else:
            header += "\n"
        
        output = header + notes
        
        # Append transcript if provided (matches Swift pipeline)
        if transcript:
            output += f"""\n\n## Full Transcript\n{transcript}\n
---
*Generated automatically by MeetingScribe*
*Recording: {recording}*"""
        
        return output


class ProcessingPipeline:
    """Main processing pipeline."""
    
    def __init__(self, config: Config, verbose: bool = False, glossary: Optional[Glossary] = None,
                 show_corrections: bool = False):
        self.config = config
        self.verbose = verbose
        self.glossary = glossary
        self.show_corrections = show_corrections
        self.transcriber = TranscriptionEngine(config, verbose)
        self.notes_gen = NotesGenerator(config, verbose, glossary=glossary)
    
    def process(
        self,
        audio_file: str,
        model: Optional[str] = None,
        prompt_file: Optional[str] = None,
        output_dir: Optional[str] = None,
        dry_run: bool = False
    ) -> Dict[str, Any]:
        """
        Process a recording end-to-end.
        
        Args:
            audio_file: Path to audio file
            model: Optional Ollama model override
            prompt_file: Optional custom prompt file
            output_dir: Optional output directory override
            dry_run: If True, skip notes generation
            
        Returns:
            Result dict with status, timings, output path
        """
        audio_file = os.path.expanduser(audio_file)
        output_dir = os.path.expanduser(output_dir or self.config.output_directory)
        
        # Ensure output directory exists
        os.makedirs(output_dir, exist_ok=True)
        
        result = {
            'status': 'processing',
            'input': audio_file,
            'output_dir': output_dir,
            'timings': {}
        }
        
        try:
            # Validate input
            if not os.path.exists(audio_file):
                raise FileNotFoundError(f"Audio file not found: {audio_file}")
            
            print(f"\n{'='*60}")
            print(f"Processing: {os.path.basename(audio_file)}")
            print(f"{'='*60}\n")
            
            # Step 1: Transcribe
            print("[Step 1/2] Transcription")
            transcript, transcription_time = self.transcriber.transcribe(audio_file)
            result['timings']['transcription'] = transcription_time
            result['transcript_length'] = len(transcript)
            
            if dry_run:
                print("\n[Dry Run] Skipping notes generation")
                result['status'] = 'success'
                result['notes'] = None
                self._print_summary(result)
                return result
            
            # Override notes generator if custom prompt provided
            if prompt_file:
                if not os.path.exists(prompt_file):
                    raise FileNotFoundError(f"Prompt file not found: {prompt_file}")
                with open(prompt_file, 'r') as f:
                    custom_prompt = f.read().strip()
                # Inject glossary context if available
                if self.glossary and self.glossary.enabled:
                    glossary_context = self.glossary.format_for_prompt()
                    if glossary_context:
                        custom_prompt += glossary_context
                self.notes_gen.system_prompt = custom_prompt
                if self.verbose:
                    print(f"[Notes] Using custom prompt: {prompt_file}")
            
            # Step 2: Generate notes
            print("\n[Step 2/2] Notes Generation")
            notes, notes_time, token_count = self.notes_gen.generate(
                transcript,
                model=model
            )
            result['timings']['notes_generation'] = notes_time
            result['timings']['total'] = transcription_time + notes_time
            result['token_count'] = token_count
            
            # Step 3: Render and save
            metadata = {
                'timestamp': datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
                'recording': os.path.basename(audio_file),
                'duration': f"{transcription_time + notes_time:.1f}s",
                'model': model or self.config.ollama_model
            }
            
            # Get the system prompt used (either custom or default)
            used_prompt = self.notes_gen.system_prompt
            
            rendered = NotesTemplate.render(notes, metadata, transcript=transcript, 
                                            system_prompt=used_prompt, glossary=self.glossary)
            
            # Save output
            output_filename = f"test_{datetime.now().strftime('%Y%m%d_%H%M%S')}.md"
            output_path = os.path.join(output_dir, output_filename)
            
            with open(output_path, 'w') as f:
                f.write(rendered)
            
            result['status'] = 'success'
            result['output_path'] = output_path
            result['output_size'] = os.path.getsize(output_path)
            result['notes'] = notes
            
            self._print_summary(result, show_corrections=self.show_corrections)
            return result
            
        except Exception as e:
            result['status'] = 'error'
            result['error'] = str(e)
            self._print_error(result)
            return result
    
    def _print_summary(self, result: Dict[str, Any], show_corrections: bool = False) -> None:
        """Print processing summary."""
        print(f"\n{'='*60}")
        print("Summary")
        print(f"{'='*60}")
        print(f"Status: {result['status'].upper()}")
        
        if result['status'] == 'success':
            print(f"Transcription: {result['timings'].get('transcription', 0):.1f}s")
            print(f"Notes generation: {result['timings'].get('notes_generation', 0):.1f}s")
            print(f"Total time: {result['timings'].get('total', 0):.1f}s")
            print(f"Transcript length: {result.get('transcript_length', 0)} chars")
            print(f"Output: {result.get('output_path', 'N/A')}")
            print(f"Output size: {result.get('output_size', 0)} bytes")
            
            # Show glossary term matches if requested
            if show_corrections and self.glossary and self.glossary.enabled:
                self._print_corrections(result)
        else:
            print(f"Error: {result.get('error', 'Unknown')}")
        
        print()
    
    def _print_corrections(self, result: Dict[str, Any]) -> None:
        """Print glossary correction analysis."""
        notes = result.get('notes', '')
        if not notes or not self.glossary:
            return
        
        matches = self.glossary.find_matches_in_text(notes)
        
        print(f"\n{'='*60}")
        print("Glossary Term Analysis")
        print(f"{'='*60}")
        
        if matches:
            print(f"Found {len(matches)} glossary terms in output:\n")
            for term, count in sorted(matches.items(), key=lambda x: -x[1]):
                print(f"  • {term}: {count} occurrence{'s' if count != 1 else ''}")
        else:
            print("No glossary terms found in output.")
            print("This may indicate:")
            print("  - Transcript didn't contain relevant terms")
            print("  - Terms were not phonetically similar to glossary entries")
            print("  - LLM didn't use the glossary context")
    
    def _print_error(self, result: Dict[str, Any]) -> None:
        """Print error summary."""
        print(f"\n{'='*60}")
        print("ERROR")
        print(f"{'='*60}")
        print(f"Error: {result.get('error', 'Unknown error')}")
        print()


def process_batch(batch_dir: str, config: Config, args: argparse.Namespace, 
                  glossary: Optional[Glossary] = None) -> None:
    """Process all .wav files in a directory."""
    batch_dir = os.path.expanduser(batch_dir)
    
    if not os.path.isdir(batch_dir):
        print(f"Error: Not a directory: {batch_dir}", file=sys.stderr)
        sys.exit(1)
    
    wav_files = list(Path(batch_dir).glob("*.wav"))
    
    if not wav_files:
        print(f"No .wav files found in {batch_dir}", file=sys.stderr)
        sys.exit(1)
    
    print(f"\nFound {len(wav_files)} recordings\n")
    
    pipeline = ProcessingPipeline(config, verbose=args.verbose, glossary=glossary,
                                   show_corrections=getattr(args, 'show_corrections', False))
    results = []
    
    for i, wav_file in enumerate(sorted(wav_files), 1):
        print(f"[{i}/{len(wav_files)}] Processing {wav_file.name}...")
        
        try:
            result = pipeline.process(
                str(wav_file),
                model=args.model,
                prompt_file=args.prompt_file,
                output_dir=args.output,
                dry_run=args.dry_run
            )
            results.append(result)
        except KeyboardInterrupt:
            print("\nInterrupted by user")
            break
        except Exception as e:
            print(f"Error: {e}")
            results.append({'status': 'error', 'input': str(wav_file), 'error': str(e)})
    
    # Print batch summary
    print(f"\n{'='*60}")
    print("Batch Summary")
    print(f"{'='*60}")
    successful = sum(1 for r in results if r['status'] == 'success')
    failed = len(results) - successful
    print(f"Processed: {len(results)}")
    print(f"Successful: {successful}")
    print(f"Failed: {failed}")
    
    if results and results[0].get('timings'):
        total_time = sum(r.get('timings', {}).get('total', 0) for r in results)
        print(f"Total time: {total_time:.1f}s")
    print()


def main():
    parser = argparse.ArgumentParser(
        description='MeetingScribe Ollama Prototyping Tool',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__
    )
    
    parser.add_argument(
        'recording',
        nargs='?',
        help='Path to recording file'
    )
    parser.add_argument(
        '--batch',
        help='Process all .wav files in directory'
    )
    parser.add_argument(
        '--model',
        help='Ollama model to use (default: from config)'
    )
    parser.add_argument(
        '--prompt-file',
        help='Custom system prompt file'
    )
    parser.add_argument(
        '--glossary',
        help='Path to glossary JSON file for term correction'
    )
    parser.add_argument(
        '--show-corrections',
        action='store_true',
        help='Show which glossary terms appear in output'
    )
    parser.add_argument(
        '--output',
        help='Output directory (default: from config)'
    )
    parser.add_argument(
        '--dry-run',
        action='store_true',
        help='Transcription only, skip notes generation'
    )
    parser.add_argument(
        '--verbose',
        action='store_true',
        help='Detailed output and timing'
    )
    
    args = parser.parse_args()
    
    # Load config
    try:
        config = Config()
    except FileNotFoundError as e:
        print(f"Error: {e}", file=sys.stderr)
        print(f"\nCreate config at: ~/.meetingscribe/config.json", file=sys.stderr)
        sys.exit(1)
    
    # Load glossary if specified
    glossary = None
    if args.glossary:
        try:
            glossary = Glossary.from_file(args.glossary)
            print(f"[Glossary] Loaded {len(glossary)} terms from {args.glossary}")
            if args.verbose:
                for entry in glossary.entries[:5]:  # Show first 5 in verbose mode
                    print(f"  - {entry.format()}")
                if len(glossary) > 5:
                    print(f"  ... and {len(glossary) - 5} more")
        except (FileNotFoundError, ValueError, json.JSONDecodeError) as e:
            print(f"Error loading glossary: {e}", file=sys.stderr)
            sys.exit(1)
    
    # Handle batch mode
    if args.batch:
        process_batch(args.batch, config, args, glossary=glossary)
        return
    
    # Handle single file mode
    if not args.recording:
        parser.print_help()
        sys.exit(1)
    
    # Process single recording
    pipeline = ProcessingPipeline(config, verbose=args.verbose, glossary=glossary,
                                  show_corrections=args.show_corrections)
    
    try:
        result = pipeline.process(
            args.recording,
            model=args.model,
            prompt_file=args.prompt_file,
            output_dir=args.output,
            dry_run=args.dry_run
        )
        
        sys.exit(0 if result['status'] == 'success' else 1)
        
    except KeyboardInterrupt:
        print("\nInterrupted by user")
        sys.exit(1)
    except Exception as e:
        print(f"\nFatal error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == '__main__':
    main()
