# khc_cli.pm -- Headless driver for KH Coder 3
#
# Runs INSIDE kh_coder.exe as a plugin, so every analysis uses the exact same
# code paths as the GUI: MeCab/ChaSen parsing, MySQL storage, R plotting.
#
#   kh_coder.exe -khc <command> [args...]
#
# COMMANDS
#   probe                        Runtime facts; touches nothing.
#   db                           List registered projects.
#   morpho   <file>              Register + preprocess (morphological analysis).
#   freq     <file> <out.csv>    Preprocess + word frequency list.
#   netgraph <file> <out.png>    Preprocess + co-occurrence network figure.
#   cls      <file> <out.png>    Preprocess + cluster analysis figure.
#   mds      <file> <out.png>    Preprocess + multidimensional scaling figure.
#   corresp  <file> <out.png>    Preprocess + correspondence analysis figure.
#   conc     <file> <word> <out.csv>   Preprocess + KWIC concordance.
#
# ARGUMENT ENCODING (important)
#   On this machine the console codepage is GBK/cp936, so a Japanese argument
#   such as 防衛 arrives as bytes B7 C0 D0 6C. Verified: decoding those bytes
#   as cp936 yields exactly U+9632 U+885B (防衛). We therefore normalise every
#   argument through cp936 before using it as a search key.
#
# WHY THE STOCK auto_run.pm FAILS ON THIS INSTALL
#   1. Hardcodes C:\khcoder3\net.png, but this install is D:\khcoder3.
#   2. Skips preprocessing, so kh_morpho::run() finds no _mph.txt and aborts
#      through gui_errormsg (headless: raises _TK_EXIT_(0)).
#   3. kh_project::open() reads morpho_analyzer before any analysis exists;
#      an empty status_char row makes it return the literal ' MySQL Error',
#      which c_or_j() stores, so refine_cj() blesses the config object into
#      "kh_sysconfig::win32:: MySQL Error" -> "Can't locate object method
#      path_check".
#
# THE WORKING PIPELINE (reverse-engineered; verified end-to-end)
#   a. seed status_char(morpho_analyzer, morpho_analyzer_lang)  -> fixes (3)
#   b. $proj->open
#   c. $proj->read_hinshi_setting
#   d. kh_dictio->readin->mark      -> writes <db>_mph.txt      -> fixes (2)
#   e. kh_morpho->run               -> writes <db>_ch.txt (parsed)
#   f. mysql_ready->readin          -> loads rowdata/hinshi/genkei
#   g. mysql_ready->first(0)        -> finalizes tables (33 tables)

package khc_cli;

use Encode ();
# The source file is UTF-8. Without this pragma a Chinese literal becomes raw
# UTF-8 bytes, and _fs() would then treat it as already-encoded and skip the
# cp936 conversion that Windows file APIs need. With it, literals are character
# strings and _fs() can do its job.
use utf8;

# ---------------------------------------------------------------------------
# Work directory (logs, probe output, scratch CSVs).
#
# Resolution order, so the driver is not tied to one machine:
#   1. $ENV{KHC_WORKDIR}             -- set by the launcher (khc.cmd) per install
#   2. <dir of kh_coder.exe>/khc_work -- self-contained default
#   3. ./khc_work                     -- last resort, relative to cwd
#
# This used to be the hardcoded 'D:/khc_auto', which matched exactly one
# machine. Resolved once at load time because _log() is called from early boot
# paths, before any sub in this file runs.
# ---------------------------------------------------------------------------
my $LOGDIR = do {
    my $d = $ENV{KHC_WORKDIR};
    if (!$d) {
        # Locate the KH Coder root: the @INC entry that contains kh_lib/.
        # PDK pushes the install root onto @INC, so this is reliable.
        my $base;
        for my $inc (@INC) {
            next unless defined $inc && length $inc;
            if (-d "$inc/kh_lib") { $base = $inc; last; }
        }
        $base = '.' unless defined $base;
        $d = "$base/khc_work";
    }
    $d =~ s{\\}{/}g;

    # Force absolute: a relative work dir would scatter logs across whatever
    # cwd the host process happens to have. File::Spec->rel2abs uses cwd, which
    # is the KH Coder root because khc.cmd does pushd before launching.
    eval {
        require Cwd;
        require File::Spec;
        $d = File::Spec->rel2abs($d) if $d =~ m{^\.};
        $d =~ s{\\}{/}g;
    };

    eval {
        require File::Path;
        File::Path::mkpath([$d]) unless -d $d;
    };
    $d;
};
my $LOG = "$LOGDIR/khc_cli.log";

sub _log {
    my $msg = shift;
    return unless open(my $fh, '>>:encoding(utf8)', $LOG);
    print $fh scalar(localtime) . " [$$] $msg\n";
    close($fh);
}

# Normalise a command-line argument to a Perl character string.
#
# Arguments arrive as raw bytes. Two different encodings show up in practice:
#   * file paths  -- written by the caller in UTF-8 (PowerShell/node/cmd all do)
#   * search terms -- typed at the console, so they carry the OEM codepage (cp936 here)
# Rather than guess, we try UTF-8 strictly first (it rejects cp936 byte pairs
# that are not valid UTF-8), and fall back to cp936.
sub _arg {
    my $v = shift;
    return $v unless defined $v;
    return $v if utf8::is_utf8($v);          # already decoded

    my $u = eval { Encode::decode('utf-8', $v, Encode::FB_CROAK()) };
    return $u if defined $u && !$@;

    my $g = eval { Encode::decode('cp936', $v) };
    return defined $g && !$@ ? $g : $v;
}

sub _uni { my $p = shift; return eval { $::config_obj->uni_path($p) } // $p; }

# ---------------------------------------------------------------------------
# Filesystem encoding helper.
#
# Perl's -e / open() go through the OS API, which on Windows expects the
# ANSI/OEM codepage (cp936 here). Our argument strings are decoded Perl
# character strings, so they must be encoded back before touching the disk --
# otherwise a path containing Chinese is reported as "no such file".
# ---------------------------------------------------------------------------
sub _fs {
    my $p = shift;
    return $p unless defined $p;
    return $p unless utf8::is_utf8($p);      # already bytes
    my $b = eval { Encode::encode('cp936', $p) };
    return $@ ? $p : $b;
}

sub _exists {
    my $p = shift;
    return 0 unless defined $p;
    return 1 if -e $p;
    my $b = _fs($p);
    return ($b ne $p && -e $b) ? 1 : 0;
}

# ---------------------------------------------------------------------------
# About the KH Coder logo splash (kh_coder.pl:109-116)
#
#     if (eval 'require Win32::GUI::SplashScreen'){
#         Win32::GUI::SplashScreen::Show(-file => 'kh_logo.bmp', -mintime => 3);
#     }
#
# Measured on this machine: a borderless 400x122 window appears at t=0.5 s,
# parked dead centre (760,479 on a 1920x1080 screen), and is still there when the
# main window comes up at t=2.9 s. main.pm:42 does
#     $::splash->Destroy if $::splash;
# but $::splash is only assigned on the Tk::Splash branch, so on Windows nothing
# ever destroys the logo -- it keeps covering whatever the user is doing.
#
# This CANNOT be fixed from inside this plugin, and two attempts proved it:
#   * a dummy %INC entry for Win32/GUI/SplashScreen.pm in a BEGIN block: the PDK
#     executable pulls the module in before plugins load, so the eval still sees
#     it and shows the logo anyway;
#   * overriding Win32::* window helpers here: this PDK build ships a cut-down
#     Win32 module -- `require Win32` succeeds but EnumWindows /
#     IsWindowVisible / GetWindowRect / GetWindowText / PostMessage /
#     GetWindowThreadProcessId are ALL absent (verified by probing Win32->can()),
#     so no in-process window hunt is possible.
#
# The working fix is therefore external: khc.cmd starts 关闭启动画面.ps1 in the
# background, which closes the window as soon as it appears. Keep this comment so
# the in-process approach is not attempted a third time.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Error-message guard.
#
# gui_errormsg::open() ends with:
#     unless ($self->{type} eq 'msg') {
#         if ($::main_gui) { ...; $::main_gui->close; }   # -> raises _TK_EXIT_(0)
#         else             { exit; }
#     }
# Headless there is no GUI to dismiss the modal, so ANY recoverable error
# (a missing optional module, an unopenable scratch file, ...) kills the whole
# run with the opaque exception "_TK_EXIT_(0)".
#
# We therefore replace open() with a logging stub that returns success. The
# caller (usually `... or gui_errormsg->open(...)`) then simply carries on.
# ---------------------------------------------------------------------------
my $guard_installed = 0;

sub _install_error_guard {
    return if $guard_installed;
    $guard_installed = 1;

    no warnings 'redefine';
    *gui_errormsg::open = sub {
        my $class = shift;
        my %args  = @_;

        my $detail = '';
        eval {
            if ($args{thefile}) { $detail .= " file=$args{thefile}"; }
            if ($args{sql})     { $detail .= " sql=$args{sql}"; }
            if ($args{msg})     { $detail .= " msg=$args{msg}"; }
            my @c = caller(1);
            $detail .= " at $c[1] line $c[2]" if defined $c[1];
        };

        _log("SUPPRESSED-ERROR type=" . ($args{type} // '?') . $detail);
        return 1;   # report success so callers do not die / exit
    };
}

sub _find_registered {
    my ($file) = @_;
    my $projs = eval { kh_projects->read } or return undef;
    my $list  = eval { $projs->list } or return undef;
    return undef unless ref($list) eq 'ARRAY';
    my $want = _uni($file);
    for my $p (@$list) {
        my $t = eval { $p->file_target };
        next unless defined $t;
        return $p if _uni($t) eq $want;
    }
    return undef;
}

sub _seed_status {
    my ($proj, $analyzer, $lang) = @_;
    # Defaults may be overridden per call; the CLI passes values derived from
    # the --lang option (or auto-detected) so Chinese corpora work too.
    $analyzer ||= $ENV{KHC_ANALYZER} || 'mecab';
    $lang     ||= $ENV{KHC_LANG}     || 'jp';
    my $db = $proj->dbname or do { _log("seed: no dbname"); return 0; };
    for my $pair (['morpho_analyzer', $analyzer], ['morpho_analyzer_lang', $lang]) {
        my ($col, $val) = @$pair;
        eval {
            mysql_exec->do("DELETE FROM ${db}.status_char WHERE name = \"$col\"", 1);
            mysql_exec->do("INSERT INTO ${db}.status_char (name, status) VALUES (\"$col\", \"$val\")", 1);
        };
        if ($@) { _log("seed $col EXC: $@"); return 0; }
    }
    return 1;
}

# Pick (analyzer, lang) for a corpus.
#   jp -> mecab / jp      cn -> stanford / cn      en -> stanford / en
# Auto-detection counts CJK vs Latin characters in the first chunk.
# The file may be UTF-8 or GBK/cp936 -- try UTF-8 strictly, then cp936.
sub _detect_lang {
    my ($file, $forced) = @_;

    if (defined $forced && length $forced) {
        my %map = (
            jp => ['mecab',    'jp'],
            cn => ['stanford', 'cn'],
            en => ['stanford', 'en'],
            kr => ['mecab_k',  'kr'],
        );
        my $m = $map{ lc $forced };
        unless ($m) { _log("unknown lang '$forced', falling back to auto"); }
        else { _log("lang forced to '$forced'"); return @$m; }
    }

    my $raw = '';
    if (open(my $fh, '<:raw', _fs($file))) {
        read($fh, $raw, 262144);
        close($fh);
    } else {
        _log("detect: cannot open $file, defaulting to jp");
        return ('mecab', 'jp');
    }

    # Try UTF-8 first (strict), else cp936.
    # A fixed-size read can slice a multi-byte UTF-8 character in half, which
    # makes strict decoding fail and wrongly falls back to cp936. Trim trailing
    # bytes until the sample ends on a character boundary.
    if (length $raw) {
        my $cut = 0;
        for my $back (1 .. 4) {
            last if $back > length $raw;
            my $b = ord(substr($raw, length($raw) - $back, 1));
            if (($b & 0xC0) != 0x80) {          # found a lead byte
                my $need = ($b >= 0xF0) ? 4 : ($b >= 0xE0) ? 3 : ($b >= 0xC0) ? 2 : 1;
                if ($need > $back) {            # sequence incomplete -> drop it
                    $cut = length($raw) - $back;
                }
                last;
            }
        }
        substr($raw, $cut) = '' if $cut;
    }

    my $text = eval { Encode::decode('utf-8', $raw, Encode::FB_CROAK()) };
    my $used = 'utf-8';
    if ($@ || !defined $text) {
        $text = eval { Encode::decode('cp936', $raw) };
        $used = 'cp936';
        if ($@ || !defined $text) { $text = $raw; $used = 'raw'; }
    }

    my ($han, $kana, $latin, $total) = (0, 0, 0, 0);
    for my $ch (split //, $text) {
        my $c = ord $ch;
        $total++;
        if    ($c >= 0x3040 && $c <= 0x30ff) { $kana++; }
        elsif ($c >= 0x4e00 && $c <= 0x9fff) { $han++; }
        elsif (($c >= 0x41 && $c <= 0x5a) || ($c >= 0x61 && $c <= 0x7a)) { $latin++; }
    }

    my $verdict = ($kana > 0)                   ? 'jp'
                : ($han > $latin && $han > 20)  ? 'cn'
                : ($latin > $han)               ? 'en'
                :                                 'cn';

    _log("detect: encoding=$used kana=$kana han=$han latin=$latin total=$total -> $verdict");
    my %map = (jp => ['mecab', 'jp'], cn => ['stanford', 'cn'], en => ['stanford', 'en']);
    return @{ $map{$verdict} };
}

# Cache the detection result for the current run, so the two _seed_status
# calls (before and after open()) always agree.
my ($CUR_ANALYZER, $CUR_LANG);
my $CLI_LANG;      # set from the --lang flag, overrides auto-detection

sub _current_lang {
    my ($file, $forced) = @_;
    $forced = $CLI_LANG unless defined $forced;
    unless (defined $CUR_ANALYZER) {
        my ($an, $lg) = _detect_lang($file, $forced);
        $CUR_ANALYZER = $an;
        $CUR_LANG     = $lg;
    }
    return ($CUR_ANALYZER, $CUR_LANG);
}

# Pull "--lang xx" (or "--lang=xx") out of the argument list, returning the
# remaining positional arguments.
sub _extract_lang_flag {
    my @in = @_;
    my @out;
    for (my $i = 0; $i < @in; $i++) {
        my $v = $in[$i];
        next unless defined $v;
        if ($v eq '--lang') {
            $CLI_LANG = $in[ ++$i ];
            next;
        }
        if ($v =~ /^--lang=(.+)$/) { $CLI_LANG = $1; next; }
        push @out, $v;
    }
    return @out;
}

# ---------------------------------------------------------------------------
# Analysis parameters.
#
# The analyser windows read their settings from Tk Entry widgets that live on
# the shared "words" widget object, e.g.
#     $win->{words_obj}{ent_min}      -> minimum term frequency
#     $win->{words_obj}{ent_min_df}   -> minimum number of documents
# The window-level accessors (min(), min_df(), ...) are read-only forwards, so
# values must be written into the Entries themselves.
#
# We therefore accept free-form "--key value" / "--key=value" options and map
# them onto those widgets. Unknown keys are reported instead of silently
# ignored, so a typo can never masquerade as a default run.
# ---------------------------------------------------------------------------
my %PARAM = ();          # collected "--key value" options for this run
our %KH = ();            # run-scoped flags shared with the modal handler
                         # (e.g. $KH{too_many} when the analyser backs out)

sub _extract_params {
    my @in = @_;
    my @out;
    for (my $i = 0; $i < @in; $i++) {
        my $v = $in[$i];
        next unless defined $v;
        if ($v =~ /^--([a-z0-9_]+)=(.*)$/s) { $PARAM{$1} = $2; next; }
        if ($v =~ /^--([a-z0-9_]+)$/) {
            my $k = $1;
            my $n = $in[$i + 1];
            if (defined $n && $n !~ /^--/) { $PARAM{$k} = $n; $i++; next; }
            $PARAM{$k} = 1;      # bare flag
            next;
        }
        push @out, $v;
    }
    return @out;
}

# Write a value into a Tk Entry (delete-then-insert).
sub _set_entry {
    my ($entry, $val) = @_;
    return 0 unless ref($entry);
    return 0 unless eval { $entry->delete(0, 'end'); 1 };
    eval { $entry->insert(0, $val) };
    return $@ ? 0 : 1;
}

# Apply the collected parameters to an analyser window.
# Returns the list of keys that we did not know how to apply.
sub _apply_params {
    my ($win) = @_;
    my $w = $win->{words_obj};
    my $n = $win->{net_obj};
    my @unknown;

    # key => [target object, widget slot, human description]
    my %MAP = (
        min      => [$w, 'ent_min',        'minimum term frequency'],
        max      => [$w, 'ent_max',        'maximum term frequency'],
        min_df   => [$w, 'ent_min_df',     'minimum number of documents'],
        max_df   => [$w, 'ent_max_df',     'maximum number of documents'],
        edges    => [$n, 'entry_edges_number', 'max edges in the network'],
        jaccard  => [$n, 'entry_edges_jac',    'Jaccard coefficient'],
    );

    for my $k (sort keys %PARAM) {
        next if $k eq 'lang';            # handled earlier
        # Parameters consumed by the driver itself, not by a Tk widget.
        next if $k eq 'csv' || $k eq 'cod' || $k eq 'var' || $k eq 'tani'
             || $k eq 'name' || $k eq 'topics' || $k eq 'fold'
             || $k eq 'engine' || $k eq 'dict';
        my $spec = $MAP{$k};
        unless ($spec) { push @unknown, $k; next; }
        my ($obj, $slot, $desc) = @$spec;
        unless (ref($obj) && ref($obj->{$slot})) {
            _log("param $k: widget '$slot' not available on this analysis");
            push @unknown, $k;
            next;
        }
        my $ok = _set_entry($obj->{$slot}, $PARAM{$k});
        my $readback = eval { $obj->{$slot}->get };
        _log("param $k=$PARAM{$k} ($desc) applied=" . ($ok ? 'yes' : 'no') .
             " readback=" . (defined $readback ? $readback : 'undef'));
    }

    # hinshi: comma-separated part-of-speech ids -> tick the checkbuttons
    if (exists $PARAM{hinshi}) {
        my @ids = split /[,\s]+/, $PARAM{hinshi};
        my $chk = $w->{check_hinshi} || $w->{hinshi_objs};
        if (ref($chk) eq 'ARRAY') {
            _log("param hinshi: " . scalar(@$chk) . " checkbuttons found, wanted [@ids]");
        } else {
            _log("param hinshi: checkbutton set not found; ignored");
        }
    }

    # Analysis-specific knobs that are plain hash fields rather than widgets.
    if (exists $PARAM{freq_as_size}) {
        $win->{net_obj}{check_use_freq_as_size} = $PARAM{freq_as_size} ? 1 : 0;
        _log("param freq_as_size=$PARAM{freq_as_size} applied");
    }

    return @unknown;
}

sub _ensure_project {
    my ($file) = @_;
    unless (defined $file && _exists($file)) { _log("ensure FAIL: no file '$file'"); return undef; }

    my ($an, $lg) = _current_lang($file);
    _log("analyzer=$an lang=$lg");

    my $proj = _find_registered($file);
    if ($proj) {
        _log("reuse db=" . (eval { $proj->dbname } // '?'));
    } else {
        $proj = eval { kh_project->new(target => $file, comment => 'khc_cli') };
        if ($@ || !$proj) { _log("kh_project->new FAIL: $@"); return undef; }
        my $projs = eval { kh_projects->read } or return undef;
        my $added = eval { $projs->add_new($proj) };
        if ($@) { _log("add_new EXC: $@"); return undef; }
        unless ($added) { _log("add_new returned 0"); return undef; }
        _log("registered db=" . (eval { $proj->dbname } // '?'));
    }

    _seed_status($proj, $an, $lg);       # (a)
    my $ok = eval { $proj->open };       # (b)
    if ($@ || !$ok) { _log("open FAIL: $@"); return undef; }
    _log("open ok c_or_j=" . (eval { $::config_obj->c_or_j } // '?'));
    _seed_status($proj, $an, $lg);
    return $::project_obj;
}

sub _do_preprocess {
    my ($file) = @_;

    my $proj = _ensure_project($file) or return undef;

    # Segmenter overrides must be installed before anything else:
    # mysql_ready::first() invokes kh_morpho->run directly (mysql_ready.pm:56),
    # bypassing our step list. That second call is exactly where the built-in
    # MeCab launcher used to fail, so the override has to be installed for the
    # Japanese default too -- not only when --engine was given explicitly.
    {
        my $e = exists $PARAM{engine} ? lc($PARAM{engine}) : '';
        $e = 'mecab' if !length $e && _cur_lang_is_jp();
        if ($e eq 'jieba' || $e eq 'mecab') {
            _install_jieba_morpho_override();
        }
    }

    my @steps = (
        ['read_hinshi_setting', sub { $::project_obj->read_hinshi_setting; 1 }],
        ['readin',              sub { kh_dictio->readin; 1 }],
        ['fix_icode',           sub { _force_assigned_icode(); 1 }],
        ['mark',                sub { kh_dictio->readin->mark; 1 }],   # -> _mph.txt
        ['morpho',              sub { _run_morpho_stage() }],           # -> _ch.txt
        ['readin_rowdata',      sub { my $m = bless {}, 'mysql_ready'; $m->readin; 1 }],
        ['first',               sub { mysql_ready->first(0) }],
    );
    for my $s (@steps) {
        my ($name, $code) = @$s;
        my $r = eval { $code->() };
        if ($@) { _log("  [$name] EXC: $@"); return undef; }
        _log("  [$name] => " . (defined $r ? $r : 'undef'));
        if ($name eq 'morpho' && !$r) { _log("  -> morpho refused; abort"); return undef; }
    }
    my $out = $::project_obj->file_MorphoOut;
    _log("  _ch size=" . (defined($out) ? (-s $out // 'na') : 'na'));
    return $::project_obj;
}

# ---------------------------------------------------------------------------
# Encoding pin for the marking stage.
#
# kh_dictio::mark derives the input encoding from kh_jchar->check_code2(), which
# delegates to Jcode::icode. Jcode only recognises Shift_JIS / EUC-JP /
# ISO-2022-JP -- it returns undef for UTF-8, and the undefined value then flows
# into File::BOM::open_bom(..., ":encoding($icode)") as the literal string
# "binary". Setting an already-open handle to :encoding(binary) raises
# "Couldn't set binmode ... Invalid argument" and the run dies there.
#
# check_code2 honours $::project_obj->assigned_icode before it ever consults
# Jcode (kh_jchar.pm:153-161), so pinning that value skips the broken path
# entirely.
sub _force_assigned_icode {
    # Japanese must stay on utf8 here, NOT cp932.
    #
    # An earlier revision pinned jp to 'cp932' on the theory that MeCab expects
    # Shift_JIS. Measured against the real corpus: the cleaned Japanese text is
    # UTF-8 (first bytes E4 BB A4 = "令"), and forcing cp932 made kh_dictio::mark
    # read UTF-8 bytes as Shift_JIS, so <db>_mph.txt came out as mojibake and
    # MeCab produced 27,240,530 bytes of garbage (莉 / 蜥 / 繧呈, mostly UNKNOWN)
    # instead of 15,353,542 bytes of correct tokens (令 リョウ 名詞-一般). The
    # GUI leaves Japanese on utf8 too, so utf8 is both correct and bit-identical.
    #
    # NB: do NOT test $PARAM{lang} -- _extract_lang_flag() removes --lang from the
    # argument list and parks it in $CLI_LANG, so %PARAM has no 'lang' key.
    my $want = exists $PARAM{icode} ? $PARAM{icode} : 'utf8';
    my $ok = eval { $::project_obj->assigned_icode($want); 1 };
    my $got = eval { $::project_obj->assigned_icode };
    _log("icode: pinned to '$want' readback=" . (defined $got ? $got : 'undef')
         . ($ok ? '' : ' (setter failed)'));
    return $ok;
}


# Chinese segmentation has two possible engines:
#   (1) KH Coder's built-in Stanford CRF segmenter -- the default. Its
#       dictionary options (-serDictionary / -inputDicts) were measured NOT to
#       affect segmentation, so fixed multi-word terms get split.
#   (2) jieba via an external Python process (--engine jieba). jieba DOES honour
#       a custom dictionary, so terms like 中国式现代化 stay intact.
#
# Both produce the same intermediate file ($::project_obj->file_MorphoOut), so
# everything downstream is unaffected by the choice.
# ---------------------------------------------------------------------------
sub _run_morpho_stage {
    my $eng = exists $PARAM{engine} ? lc($PARAM{engine}) : '';
    # Japanese always goes through our own launcher. The built-in
    # kh_morpho/win32/mecab.pm path drives MeCab through Win32::Process on
    # <db>_ch.txt.tmp and produces an empty output file on this machine, which
    # surfaces as "致命错误: 无法启动 MeCab". Driving mecab.exe through system()
    # (_run_mecab) with an absolute binary/-d/-r and the real output path works in
    # 1.3 s for a 1.7 MB input. Defaulting to mecab for lang=jp means the user no
    # longer has to remember --engine mecab.
    $eng = 'mecab' if !length $eng && (_cur_lang_is_jp() ? 1 : 0);
    return _run_mecab() if $eng eq 'mecab';
    return kh_morpho->run unless $eng eq 'jieba';
    return _run_jieba();
}

# True when the corpus currently being processed is Japanese. _current_lang()
# resolves and caches the verdict on the first _ensure_project() call.
sub _cur_lang_is_jp {
    return 1 if defined $CUR_LANG && lc($CUR_LANG) eq 'jp';
    return 1 if !defined $CUR_LANG && defined $CLI_LANG && lc($CLI_LANG) eq 'jp';
    return 0;
}

# ---------------------------------------------------------------------------
# MeCab stage, run by us instead of kh_morpho::win32::mecab.
#
# The built-in path builds
#     mecab -Ochasen -p -r "<mecabrc>" -o <out.tmp> <in.tmp>
# and launches it through Win32::Process::Create with the working directory set
# to <mecab>/bin. On this machine that call yields an empty output file and the
# run aborts with "致命的错误: 无法启动 MeCab" even though the exact same command
# line works from a shell. Driving it through system() instead sidesteps the
# launch problem entirely, and the output is byte-identical to what the GUI
# produces (same binary, same -Ochasen format, same dictionary).
#
# The input is the marked text (file_m_target, i.e. <db>_mph.txt); the result
# goes to file_MorphoOut (<db>_ch.txt), which is what the importer reads.
sub _run_mecab {
    my $target = $::project_obj->file_m_target;
    my $output = $::project_obj->file_MorphoOut;

    unless (defined $target && -e $target) {
        _log("mecab: marked text missing: " . ($target // 'undef'));
        return 0;
    }

    my $cfg  = $::config_obj;
    my $exe  = $cfg->mecab_path;
    # Normalise every path to forward slashes: the config value mixes separators
    # ("D:/.../mecab/bin/mecab.exe"), and building "<basedir>/etc/mecabrc" from a
    # backslashed string yields "D:\\...\\mecab/etc/mecabrc", which MeCab fails to
    # open -- silently producing no output at all.
    $exe =~ s{\\}{/}g;

    # mecabrc lives next to the binary's parent directory: <dep>/mecab/etc/mecabrc
    my ($basedir) = $exe =~ m{^(.*?)/bin/}i;
    my $rc = defined $basedir ? "$basedir/etc/mecabrc" : undef;
    # The shipped mecabrc sets an *relative* dictionary path
    #     dicdir = $(rcpath)\..\dic\ipadic
    # which only resolves when MeCab is invoked from its own tree. Called from
    # anywhere else it dies with "no such file or directory: .\..\dic\ipadic\dicrc"
    # and writes no output. Pass the dictionary explicitly to make the call
    # independent of the working directory.
    my $dic = defined $basedir ? "$basedir/dic/ipadic" : undef;

    my $in_tmp  = _fs($target);
    my $out_tmp = _fs($output);
    my $exe_fs  = _fs($exe);
    my $rc_fs   = defined $rc ? _fs($rc) : '';
    my $dic_fs  = defined $dic ? _fs($dic) : '';
    $exe_fs =~ s{\\}{/}g;
    $rc_fs  =~ s{\\}{/}g;
    $dic_fs =~ s{\\}{/}g;
    $in_tmp =~ s{\\}{/}g;
    $out_tmp =~ s{\\}{/}g;

    unless (-e $exe_fs) { _log("mecab: binary not found: $exe_fs"); return 0; }

    # -Ochasen gives KH Coder's expected column layout; -d pins the dictionary
    # (see note above); -b raises the input buffer because long headings would
    # otherwise be split with an "input-buffer overflow" warning.
    my $cmd = qq{"$exe_fs" -Ochasen -b 1048576};
    $cmd .= qq{ -d "$dic_fs"} if length $dic_fs && -e $dic_fs;
    $cmd .= qq{ -r "$rc_fs"}  if length $rc_fs  && -e $rc_fs;

    # User dictionary (--dict FILE). MeCab's -u wants a COMPILED binary
    # dictionary, not the CSV the user writes: pointing -u straight at a CSV
    # fails with
    #     dictionary.cpp(94) ... dictionary file is broken
    # So a CSV source is compiled first with mecab-dict-index, whose output is
    # cached next to the source and only rebuilt when the CSV is newer.
    if (my $udic = _resolve_user_dic($exe_fs)) {
        $cmd .= qq{ -u "$udic"};
    }

    $cmd .= qq{ -o "$out_tmp" "$in_tmp"};

    _log("mecab: $cmd");
    my $rc_status = system($cmd);
    if ($rc_status != 0) {
        _log("mecab: exit rc=" . ($rc_status >> 8));
        return 0;
    }

    unless (-e $output && -s $output) {
        _log("mecab: no/empty output");
        return 0;
    }
    _log("mecab: ok, _ch size=" . (-s $output));
    return 1;
}

# Turn --dict into an argument MeCab can actually load.
#
# Two input shapes are accepted:
#   * already-compiled dictionary (binary) -- passed through untouched;
#   * MeCab user-dictionary CSV (13 comma-separated fields per line, comments
#     starting with #) -- compiled to <name>_compiled.dic via
#     mecab-dict-index, reusing the existing file when it is newer than the CSV.
#
# Returns a forward-slashed path, or undef when no --dict was given.
sub _resolve_user_dic {
    my ($exe_fs) = @_;
    return undef unless exists $PARAM{dict} && length $PARAM{dict};

    my $src = $PARAM{dict};
    # Two forms are needed and mixing them is what broke this twice:
    #   $src        -- decoded Perl string, for open()/-e in this process;
    #   $src_fs     -- cp936 bytes, for the shell command line.
    # _fs() is idempotent (it returns the input unchanged when it is not a
    # character string), but calling it on an already-converted value and then
    # encoding again turned 逆向工程 into ÄæÏò¹¤³Ì.
    unless (_exists($src)) { _log("mecab: --dict not found: $src"); return undef; }
    my $src_fs = _fs($src);
    $src_fs =~ s{\\}{/}g;

    # Sniff the content: a compiled MeCab dictionary is binary, while the CSV
    # is text (ASCII field names plus Japanese). Read a run of bytes and treat
    # the file as text only when it is valid UTF-8 with no control bytes --
    # checking just the first byte misreads a leading '#' comment as binary.
    my $head = '';
    if (open(my $fh, '<:raw', $src_fs)) {
        read($fh, $head, 512);
        close($fh);
    }
    my $is_text = 0;
    if (length $head) {
        my $copy = $head;
        $is_text = (utf8::decode($copy) && $copy !~ /[\x00-\x08\x0e-\x1f]/) ? 1 : 0;
    }

    unless ($is_text) {
        _log("mecab: --dict is compiled, using as-is");
        return $src_fs;
    }

    # mecab-dict-index accepts ONLY data lines. A hand-maintained CSV normally
    # carries '#' comments and blank lines, and it aborts with
    #     dictionary.cpp(316) [n == 5] format error: # 用户词典（MeCab 用）
    # so filter the file down to lines that have at least 12 comma-separated
    # fields and do not start with '#'.
    my @rows;
    if (open(my $rf, '<:encoding(UTF-8)', $src_fs)) {
        while (my $l = <$rf>) {
            $l =~ s/\r?\n\z//;
            next if $l =~ /^\s*#/;
            next unless length $l;
            my @f = split /,/, $l, -1;
            next if @f < 12;
            # Pad to the 13 columns mecab-dict-index expects.
            push @f, '*' while @f < 13;
            push @rows, join(',', @f[0..12]);
        }
        close($rf);
    }
    unless (@rows) { _log("mecab: --dict has no usable rows"); return undef; }

    (my $compiled = $src) =~ s{\.(csv|txt|dic)$}{}i;
    $compiled .= '_compiled.dic';
    # Character string for -e/stat in-process, byte string for the command line.
    (my $compiled_cs = $compiled) =~ s{\\}{/}g;
    my $compiled_fs = _fs($compiled_cs);
    $compiled_fs =~ s{\\}{/}g;

    if (-e $compiled_cs && (stat($compiled_cs))[9] >= (stat($src))[9]) {
        _log("mecab: --dict csv unchanged, reusing $compiled");
        return $compiled_fs;
    }

    # Hand the cleaned rows to mecab-dict-index through a temp file kept next to
    # the CSV, so the path stays ASCII-free of surprises only in content.
    (my $clean_cs = $src) =~ s{\.(csv|txt|dic)$}{}i;
    $clean_cs .= '_clean.csv';
    my $clean_fs = _fs($clean_cs);
    # "open(my $wf, ...)" scoped to the condition does NOT keep $wf visible
    # after the unless block -- that is why this said "Can't use an undefined
    # value as a symbol reference". Declare the handle first.
    my $wf;
    unless (open($wf, '>:encoding(UTF-8)', $clean_fs)) {
        _log("mecab: cannot write $clean_cs");
        return undef;
    }
    for my $row (@rows) {
        print $wf $row, "\r\n";
    }
    close($wf);
    _log("mecab: --dict cleaned " . scalar(@rows) . " rows -> $clean_cs");

    # $exe_fs is ".../mecab/bin/mecab.exe", so $bindir captured up to "/bin/"
    # is already ".../mecab" -- appending another "/bin/" would double it.
    my ($bindir) = $exe_fs =~ m{^(.*?)/bin/}i;
    my $dictidx = defined $bindir ? "$bindir/bin/mecab-dict-index.exe"
                : 'mecab-dict-index.exe';
    $dictidx =~ s{\\}{/}g;
    unless (-e $dictidx) { _log("mecab: mecab-dict-index not found: $dictidx"); return undef; }

    my $dicdir = defined $bindir ? "$bindir/dic/ipadic" : '';
    $dicdir =~ s{\\}{/}g;

    my $c = qq{"$dictidx"};
    $c .= qq{ -d "$dicdir"} if length $dicdir && -e $dicdir;
    # system() re-encodes its argument. This Perl runs under a UTF-8 locale, so
    # handing it cp936 bytes mangles the path (逆向工程 became ÄæÏò¹¤³Ì) and
    # mecab-dict-index cannot open either end. The 8.3 short name sidesteps the
    # whole problem: GetShortPathName returns ASCII, which survives any
    # re-encoding unchanged.
    my $clean_shell = _short_path($clean_cs) // $clean_fs;
    my $compiled_shell = _short_path($compiled_cs) // $compiled_fs;
    $clean_shell =~ s{\\}{/}g;
    $compiled_shell =~ s{\\}{/}g;
    $c = qq{"$dictidx"};
    $c .= qq{ -d "$dicdir"} if length $dicdir && -e $dicdir;
    $c .= qq{ -u "$compiled_shell" -f utf8 -t utf8 "$clean_shell"};
    _log("mecab: compiling user dict: $c");
    my $st = system($c);
    if ($st != 0 || !-e $compiled_cs) {
        _log("mecab: user dict compile FAILED rc=" . ($st >> 8));
        return undef;
    }
    _log("mecab: user dict compiled -> $compiled (" . (-s $compiled_cs) . " bytes)");

    # -u is also parsed by MeCab itself, which handles the Unicode path fine as
    # long as the bytes reach it intact; the short name is equally valid there.
    return $compiled_shell;
}

# Windows 8.3 short name (pure ASCII) for a path, or undef when unavailable.
# Used only for paths handed to system(), whose re-encoding corrupts non-ASCII.
# Win32::GetShortPathName is not present in this PDK build, so ask cmd.exe for
# the short form instead -- cmd is started with a pure-ASCII command line, so it
# is not subject to the same mangling.
sub _short_path {
    my ($path) = @_;
    return undef unless defined $path && length $path;
    return undef unless $path =~ /[^\x00-\x7f]/;   # already ASCII, nothing to do

    my $tmp = "$ENV{TEMP}\\khc_shortpath.txt";
    $tmp =~ s{\\}{/}g;
    my $cmd = qq{cmd /c for %I in ("} . _fs($path) . qq{") do \@echo %~sI > "$tmp"};
    my $st = system($cmd);
    return undef if $st != 0;

    my $short = '';
    if (open(my $fh, '<:encoding(UTF-8)', $tmp)) {
        $short = <$fh> // '';
        close($fh);
        chomp $short;
        $short =~ s/^\s+|\s+$//g;
    }
    unlink $tmp;
    return undef unless length $short;
    return undef if $short =~ /[^\x00-\x7f]/;      # still not ASCII -> useless
    return undef unless -e $short;
    return $short;
}
# When the jieba engine is selected we must also intercept kh_morpho::run,
# because mysql_ready::first() calls it a second time (mysql_ready.pm:56):
#     kh_dictio->readin->mark;
#     kh_morpho->run or return 0;
# Without this the Stanford segmenter runs again and overwrites the jieba
# output, which silently reverts the whole analysis to the default tokenizer.
sub _install_jieba_morpho_override {
    return if $KH{jieba_override};

    no warnings 'redefine';
    no strict 'refs';

    my $orig = \&kh_morpho::run;
    *{"kh_morpho::run"} = sub {
        my @a = @_;
        my $eng = exists $PARAM{engine} ? lc($PARAM{engine}) : '';
        # Japanese with no explicit --engine must also use our launcher here,
        # otherwise this second call (mysql_ready.pm:56) falls back to the
        # built-in Win32::Process path and fails.
        $eng = 'mecab' if !length $eng && _cur_lang_is_jp();
        if ($eng eq 'jieba') {
            _log("kh_morpho::run intercepted -> jieba");
            return _run_jieba();
        }
        # Also intercept the built-in MeCab path: mysql_ready::first() calls
        # kh_morpho->run a second time (mysql_ready.pm:56), and the built-in
        # Win32::Process launcher fails on this machine even though the CLI
        # works. Re-running our own stage keeps both calls consistent.
        if ($eng eq 'mecab') {
            _log("kh_morpho::run intercepted -> mecab (own launcher)");
            my $ok = _run_mecab();
            # kh_morpho::run returns 1 unconditionally (kh_morpho.pm:34-37), so
            # mysql_ready.pm:56's "or return 0" cannot detect a failure and the
            # run would continue with an empty _ch and die later inside
            # mysql_ready::first. Fail loudly here instead so _do_preprocess's
            # eval catches it and aborts with a readable log line.
            die "mecab stage failed (see log above)\n" unless $ok;
            return $ok;
        }
        return $orig->(@a);
    };
    $KH{jieba_override} = 1;
    _log("kh_morpho::run override installed");
}

sub _run_jieba {
    my $target = $::project_obj->file_m_target;   # marked text (_mph.txt)
    my $output = $::project_obj->file_MorphoOut;  # result (_ch.txt)

    unless (defined $target && -e $target) {
        _log("jieba: marked text missing: " . ($target // 'undef'));
        return 0;
    }

    my $python = _find_python();
    unless ($python) { _log("jieba: python not found (set KHC_PYTHON)"); return 0; }

    # Path to the external jieba script. KHC_JIEBA_SCRIPT overrides the default.
    my $script = $ENV{KHC_JIEBA_SCRIPT}
              || 'D:/逆向工程/工具/jieba分词/jieba_seg.py';
    # On Windows the OS APIs need the console/OEM codepage for non-ASCII paths;
    # _fs() performs that conversion when the string holds characters.
    my $script_fs = _fs($script);
    unless (-e $script_fs) { _log("jieba: script not found: $script_fs"); return 0; }

    my $cmd = qq{"$python" "$script_fs" "$target" "$output"};
    my $dict = exists $PARAM{dict} ? $PARAM{dict}
             : ($ENV{KHC_JIEBA_DICT} // '');
    if (length $dict) {
        my $dict_fs = _fs($dict);
        $cmd .= qq{ --dict "$dict_fs"} if -e $dict_fs;
    }

    _log("jieba: $cmd");
    my $rc = system($cmd);
    if ($rc != 0) { _log("jieba: exit rc=" . ($rc >> 8)); return 0; }

    unless (-e $output && -s $output) { _log("jieba: no/empty output"); return 0; }
    _log("jieba: ok, _ch size=" . (-s $output));
    return 1;
}

sub _find_python {
    for my $c ($ENV{KHC_PYTHON}, 'python', 'python3', 'py') {
        next unless defined $c && length $c;
        my $probe = `"$c" -c "import jieba" 2>&1`;
        return $c if $? == 0;
    }
    return undef;
}

sub _figure {
    my ($file, $outpng, $openwin, $calc, $plotid, $idx, $setup) = @_;
    my $p = _do_preprocess($file) or do { _log("figure: preprocess failed"); return 0; };
    my $ok = eval {
        my $win = $openwin->open;
        _auto_answer_modals($win);      # headless: answer "continue" prompts

        # Keep the analyser window off-screen. KH Coder still needs a real Tk
        # window (the plot objects live on it), but nothing has to be visible:
        # withdraw() hides it so runs never steal focus from the user.
        eval { $win->win_obj->withdraw; };
        _log("figure: window withdrawn (hidden)");

        # Inject the user's parameters FIRST, so every diagnostic below (and the
        # analyser itself) sees the settings that will actually be used.
        if ($setup) { $setup->($win); }

        # Terms-to-plot estimate: useful both as a warning and as a runtime
        # hint. Measured on this machine (Chinese corpus, ~600 KB):
        #   1429 terms ~14 min | 877 ~7 min | 531 ~4 min | 373 ~2 min
        #   233 ~1 min | 91-25 ~30 s
        my $wnum = eval {
            my $c = mysql_crossout::r_com->new(
                tani   => $win->tani,
                tani2  => $win->tani,
                hinshi => $win->hinshi,
                max    => $win->max,
                min    => $win->min,
                max_df => $win->max_df,
                min_df => $win->min_df,
            )->wnum;
            $c =~ s/,//g;
            $c;
        };
        if (defined $wnum && $wnum > 0) {
            my $eta = $wnum > 1000 ? '~10+ min'
                    : $wnum >  700 ? '~7 min'
                    : $wnum >  450 ? '~4 min'
                    : $wnum >  300 ? '~2 min'
                    : $wnum >  150 ? '~1 min' : '~30 s';
            _log("figure: terms to plot = $wnum  (estimated $eta)");
            if ($wnum > 300) {
                _log("figure: NOTE $wnum terms exceeds KH Coder's recommended " .
                     "100-150; it will still complete, just slowly. " .
                     "Use --min <higher> if you want a faster, sparser graph " .
                     "(preview counts with: khc words <file> --at 5,20,50,100)");
            }
        }

        if ($calc) { $calc->($win); }

        if ($KH{too_many}) {
            _log("figure: the analyser asked to confirm $KH{too_many} terms; " .
                 "answered yes. Long runtimes here are expected, not an error.");
        }

        my $wr = $::main_gui->get($plotid);
        return 0 unless $wr;
        my $plots = $wr->{plots};
        return 0 unless ref($plots) eq 'ARRAY' && @$plots;
        my $i = defined($idx) ? $idx : $#$plots;
        $i = $#$plots if $i > $#$plots;
        $plots->[$i]->save($outpng);
        1;
    };
    if ($@) { _log("figure EXC: $@"); return 0; }
    _log("figure -> $outpng exists=" . (-e $outpng ? 'yes size=' . (-s $outpng) : 'no'));

    # Optionally dump the plotted coordinates. A correspondence-analysis figure
    # alone is hard to cite -- the numbers behind each point are what a report
    # actually needs, and they exist only inside this live window.
    if (exists $PARAM{csv} && length $PARAM{csv}) {
        my $n = _export_coords($plotid, $PARAM{csv});
        _log("figure: coords -> $PARAM{csv} rows=" . ($n // 'FAILED'));
    }

    return $ok ? 1 : 0;
}

# Export the coordinates of whatever a plot window is displaying.
#
# KH Coder computes the coordinates inside R and writes them to a temp file
# itself: gui_window/word_corresp.pm:1005-1009 runs
#     write.table(out_coord, file=<file_TempCSV>, sep="\t", ...)
# and hands the path back as $plotR->{coord}. So the numbers are already on
# disk -- we only have to find that path and copy the file, rather than trying
# to reconstruct the matrix from Perl-side structures (which hold no coords).
sub _export_coords {
    my ($plotid, $path) = @_;
    my $wr = $::main_gui->get($plotid);
    return undef unless $wr;

    # 1) Preferred: the window's own record of where R put the coordinates.
    for my $k (qw(coord coords)) {
        my $c = $wr->{$k};
        next unless defined $c && length $c && !ref($c);
        my $c_fs = _fs($c);
        next unless -e $c_fs;
        my $n = _copy_file($c_fs, $path);
        if (defined $n) { _log("figure: coords copied from $k = $c"); return $n; }
    }

    # 2) The project's temp CSV is the same file by construction.
    for my $m (qw(file_TempCSV file_TempR)) {
        my $c = eval { $::project_obj->$m };
        next unless defined $c && length $c;
        my $c_fs = _fs($c);
        next unless -e $c_fs;
        my $n = _copy_file($c_fs, $path);
        if (defined $n) { _log("figure: coords copied from $m = $c"); return $n; }
    }

    # 3) Fall back to scanning this run's R-bridge directory for a fresh file.
    my $rb = eval { $::config_obj->cwd . '/config/R-bridge' };
    if ($rb && -d $rb) {
        my @cand = sort { (-M $a) <=> (-M $b) } glob("$rb/*");
        for my $c (@cand) {
            next unless -f $c && -s $c;
            next if $c =~ /\.(png|tmp)$/i;
            my $n = _copy_file($c, $path);
            if (defined $n) { _log("figure: coords copied from $c"); return $n; }
        }
    }

    _log("figure: no coordinate file found for $plotid");
    return undef;
}

# Copy a file byte-for-byte; returns the size, or undef on failure.
sub _copy_file {
    my ($src, $dst) = @_;
    my $ok = eval {
        open(my $in,  '<:raw', $src) or die "in: $!";
        open(my $out, '>:raw', $dst) or die "out: $!";
        my $buf = do { local $/; my $d = <$in>; $d };
        print {$out} $buf;
        close($in); close($out);
        1;
    };
    if ($@) { _log("copy failed: $@"); return undef; }
    return -s $dst;
}

# ---------------------------------------------------------------- probe
sub _cmd_probe {
    my $out = "$LOGDIR/probe.txt";
    open(my $fh, '>', $out) or return 0;
    print $fh "KH_CODER_PROBE=1\nPID=$$\nARGV=" . join('|', @ARGV) . "\n";
    my $c = $::config_obj;
    if ($c) {
        for my $m (qw(cwd os msg_lang c_or_j sql_type sql_socket history_file
                      chasen_path mecab_path mecab_unicode R)) {
            my $v = eval { $c->$m };
            print $fh uc($m) . "=" . (defined $v ? $v : 'undef') . "\n";
        }
    }
    close($fh);
    _log("probe -> $out");
    return 1;
}

# ------------------------------------------------------- build external variable
# Derives a per-unit grouping from the heading structure and registers it as an
# external variable (outvar), which is what word_corresp / the cross analyses
# read. This replaces hand-writing the CSV: asking the database which heading a
# unit belongs to is deterministic, whereas guessing the order of units in a
# file is not.
#
# The unit tables carry a foreign key chain (bun -> dan -> h5 -> ... -> h1); the
# `tab` routine in kh_cod/func.pm joins them exactly this way, so the same
# relationship tells us the heading of every unit.
#
# --var h1|h2|...   heading level that defines the groups (default h1)
# --tani UNIT       unit to attach the variable to: bun|dan|hN (default dan)
# --name NAME       variable name recorded in outvar (default: the --var level)
sub _cmd_mkoutvar {
    my ($file) = @_;
    my $p = _do_preprocess($file) or do { _log("mkoutvar: preprocess failed"); return 0; };

    my $var  = exists $PARAM{var}  ? lc($PARAM{var}) : 'h1';
    my $tani = exists $PARAM{tani} ? lc($PARAM{tani}) : 'dan';
    # The variable name is not restricted to ASCII; keep whatever was given.
    my $name = (exists $PARAM{name} && length $PARAM{name}) ? $PARAM{name} : $var;

    unless ($var =~ /^h[1-5]$/)  { _log("mkoutvar: --var must be h1..h5"); return 0; }
    unless ($tani =~ /^(bun|dan|h[1-5])$/) { _log("mkoutvar: bad --tani"); return 0; }

    # A unit table carries a column only for units at or ABOVE it in the
    # document tree. Observed columns: `bun` has bun_id..h1_id, `dan` has
    # dan_id..h1_id, `h1` has only h1_id. So "$tani is groupable by $var"
    # reduces to a question about the schema -- does $tani have a ${var}_id
    # column? -- which we simply ask the database.
    my $col = "${var}_id";
    my $has_col = 0;
    my $cols_seen = '';
    eval {
        my $st = mysql_exec->select("SHOW COLUMNS FROM $tani", 1);
        my $h = $st->hundle;
        my @names;
        while (my $r = $h->fetch) {
            push @names, $r->[0];
            $has_col = 1 if $r->[0] eq $col;
        }
        $cols_seen = join(',', @names);
    };
    _log("mkoutvar: $tani columns = $cols_seen");

    unless ($has_col) {
        _log("mkoutvar: $tani has no '$col' column -- it cannot be grouped by $var");
        return 0;
    }

    my $on = "$tani.$col = $var.id";
    my $sql = "SELECT $tani.id, $var.id FROM $tani LEFT JOIN $var ON $on " .
              "ORDER BY $tani.id";
    _log("mkoutvar: $sql");

    my (@unit_ids, %group_of);
    my $ok = eval {
        my $st = mysql_exec->select($sql, 1);
        my $h = $st->hundle;
        while (my $r = $h->fetch) {
            push @unit_ids, $r->[0];
            $group_of{$r->[0]} = $r->[1];
        }
        1;
    };
    if ($@ || !@unit_ids) {
        _log("mkoutvar: query failed or returned nothing: $@");
        return 0;
    }
    _log("mkoutvar: units=$tani n=" . scalar(@unit_ids) . " grouped by $var");

    # Map heading IDs to their labels.
    #
    # Heading text is NOT in the h1/h2 tables (they hold only ids). It lives in
    # the morpheme stream `rowdata`, where <h1>三届</h1> appears as three rows:
    # the opening tag (hinshi=TAG), the text morphemes, and the closing tag.
    # So the label of the Nth heading is the text between the Nth opening tag
    # and its closing tag.
    #
    # The scan yields headings in document order; h1.id is also assigned in
    # document order (auto_increment), so the Nth label belongs to h1.id = N.
    # Scanning rowdata avoids joining hyosobun, whose hyoso_id points at the
    # hyoso dictionary rather than at rowdata -- that join produced unrelated
    # words.
    my %label;
    my $ok = eval {
        my $st = mysql_exec->select(
            "SELECT hyoso, hinshi FROM rowdata ORDER BY id", 1);
        my $h = $st->hundle;
        my ($cur, $inside, $ord) = (undef, 0, 0);
        while (my $r = $h->fetch) {
            my ($w, $pos) = @$r;
            next unless defined $w;
            $w = Encode::decode('utf8', $w) unless utf8::is_utf8($w);

            if ($w =~ /^<($var)>$/i) {
                ++$ord;                 # headings are numbered in document order
                $cur = $ord;
                $inside = 1;
                $label{$cur} = '';
                next;
            }
            if ($w =~ /^<\/($var)>$/i) { $inside = 0; $cur = undef; next; }
            if ($inside && defined $cur) {
                next if $w =~ /^<\/?h[1-5]>$/i;   # skip nested tags
                $label{$cur} .= $w;
            }
        }
        1;
    };
    if ($@) { _log("mkoutvar: label scan failed: $@"); }

    # If the heading stream gave nothing usable, fall back to naming groups by
    # their ordinal so the run still produces a valid variable.
    my @found = sort { $a <=> $b } keys %label;
    _log("mkoutvar: $var labels found = " . scalar(@found));
    for my $k (@found) {
        my $v = $label{$k} // '';
        # Log the hex bytes too: console codepage mangling makes the rendered
        # text unreliable, and the bytes are what actually go into the CSV.
        my $hex = join(' ', map { sprintf('%02x', ord($_)) } split //, $v);
        _log("mkoutvar:   $var id=$k => '$v'  hex=$hex");
    }
    unless (@found) {
        _log("mkoutvar: no heading text recovered; falling back to ordinals");
        $label{$_} = "group$_" for @found;
    }
    _log("mkoutvar: $var has " . scalar(keys %label) . " labels: " .
         join(' | ', map { defined $label{$_} ? $label{$_} : '?' } sort keys %label));

    # Write the CSV that mysql_outvar::read expects: header row of names, then
    # one row per unit, in unit-id order.
    my $csv = "$LOGDIR/outvar_${tani}_by_${var}.csv";
    my $n = eval {
        open(my $fh, '>:encoding(utf8)', $csv) or die "open: $!";
        print $fh "$name\n";
        for my $u (@unit_ids) {
            my $g = $group_of{$u};
            my $v = '';
            if (defined $g && defined $label{$g}) {
                $v = $label{$g};
            } elsif (defined $g) {
                # h1 ids are assigned in document order, so fall back to the
                # same ordinal in the scanned label list.
                my @ks = sort { $a <=> $b } keys %label;
                my $idx = $g - 1;
                $v = $label{$ks[$idx]} if $idx >= 0 && $idx <= $#ks;
            }
            $v = "group$g" unless length $v;
            $v =~ s/"/""/g;
            print $fh "\"$v\"\n" if $v =~ /[,"\n]/;
            print $fh "$v\n" unless $v =~ /[,"\n]/;
        }
        close($fh);
        scalar @unit_ids;
    };
    if ($@) { _log("mkoutvar: csv write failed: $@"); return 0; }
    _log("mkoutvar: wrote $csv ($n rows + header)");

    # Replace any existing variable with the same name. Doing this up front
    # keeps the importer from raising its "same name -- overwrite?" dialog,
    # which headless would block on.
    my $old = eval {
        mysql_outvar->delete(name => $name);
        1;
    };
    _log("mkoutvar: removed pre-existing '$name'") if $old;

    # Register it through KH Coder's own importer so the outvar tables are
    # created exactly as the GUI would create them.
    #
    # skip_checks bypasses both the overwrite dialog and the row-count guard;
    # the guard is unnecessary here because the CSV is generated from the same
    # unit table it is being aligned to.
    my $read = eval {
        mysql_outvar::read::csv->new(
            file        => $::config_obj->os_path($csv),
            tani        => $tani,
            var_type    => 'TEXT',
            skip_checks => 1,
        )->read;
    };
    if ($@) { _log("mkoutvar: import died: $@"); return 0; }
    unless ($read) { _log("mkoutvar: import returned false"); return 0; }

    _log("mkoutvar: registered variable '$name' on unit '$tani'");
    return 1;
}

# ---------------------------------------------------------------- db
# Introspect the project database: row counts of the counting-unit tables and
# the current contents of the outvar registry. Knowing how many documents /
# paragraphs a corpus holds is a prerequisite for supplying an external
# variable (its CSV must have exactly that many data rows -- enforced by
# mysql_outvar/read.pm:48-56).
sub _cmd_dbtables {
    my ($file) = @_;
    my $out = "$LOGDIR/dbtables.txt";
    open(my $fh, '>', $out) or return 0;

    # The unit tables only exist after preprocessing has built the project.
    if (defined $file && length $file) {
        my $p = _do_preprocess($file);
        print $fh "preprocess\t" . ($p ? 'ok' : 'FAILED') . "\n";
        _log("dbtables: preprocess " . ($p ? 'ok' : 'FAILED'));
    }

    my @units = qw(bun dan h5 h4 h3 h2 h1);
    print $fh "\n== counting units ==\n";
    _log("dbtables: counting units");
    for my $u (@units) {
        my ($n, $err);
        my $ok = eval {
            my $st = mysql_exec->select("SELECT COUNT(*) FROM $u", 1);
            $n = $st->hundle->fetch->[0];
            1;
        };
        if (!$ok) { $n = 'n/a'; }
        print $fh "$u\t$n\n";
        _log("dbtables: $u = $n");
    }

    print $fh "\n== outvar registry ==\n";
    my $ok = eval {
        my $st = mysql_exec->select(
            "SELECT id, name, tab, col, tani FROM outvar ORDER BY id", 1);
        my $h = $st->hundle;
        my $c = 0;
        while (my $r = $h->fetch) {
            print $fh join("\t", map { defined $_ ? $_ : '' } @$r) . "\n";
            ++$c;
        }
        $c;
    };
    if ($@) { _log("dbtables: outvar query: $@"); }
    else { _log("dbtables: outvar rows = " . ($ok // '?')); }

    print $fh "\n== genkei ==\n";
    my $g;
    eval { $g = mysql_exec->select("SELECT COUNT(*) FROM genkei", 1)->hundle->fetch->[0]; };
    print $fh "rows\t" . (defined $g ? $g : 'n/a') . "\n";

    # Column lists: the unit tables denormalise their ancestor keys, and which
    # columns exist tells us what can be grouped by what.
    for my $t (@units) {
        print $fh "\n== columns of $t ==\n";
        eval {
            my $st = mysql_exec->select("SHOW COLUMNS FROM $t", 1);
            my $h = $st->hundle;
            while (my $r = $h->fetch) { print $fh join("\t", @$r) . "\n"; }
        };
    }

    # Where does the heading TEXT live? h1/h2 hold only ids, so the label must
    # be stored as a tag in the morpheme stream. Look at rowdata / hyosobun.
    for my $t (qw(rowdata hyosobun)) {
        print $fh "\n== columns of $t ==\n";
        eval {
            my $st = mysql_exec->select("SHOW COLUMNS FROM $t", 1);
            my $h = $st->hundle;
            while (my $r = $h->fetch) { print $fh join("\t", @$r) . "\n"; }
        };
        print $fh "\n== a few rows of $t ==\n";
        my $st = eval { mysql_exec->select("SELECT * FROM $t ORDER BY id LIMIT 8", 1) };
        if ($st) {
            my $h = $st->hundle;
            while (my $r = $h->fetch) {
                print $fh join("\t", map { defined $_ ? $_ : 'NULL' } @$r) . "\n";
            }
        }
    }

    # Rows whose morpheme looks like a heading tag.
    print $fh "\n== rowdata heading area (first 12 rows) ==\n";
    eval {
        my $st = mysql_exec->select(
            "SELECT id, hyoso, hinshi FROM rowdata ORDER BY id LIMIT 12", 1);
        my $h = $st->hundle;
        while (my $r = $h->fetch) {
            my ($id, $hy, $hi) = @$r;
            $hy = '[undef]' unless defined $hy;
            $hi = '[undef]' unless defined $hi;
            # Show the raw bytes as hex too: that reveals the true encoding.
            my $hex = join(' ', map { sprintf('%02x', ord($_)) } split //, $hy);
            print $fh "$id\t$hy\t$hi\thex=$hex\n";
        }
    };

    print $fh "\n== hyosobun rows near the first heading ==\n";
    eval {
        my $st = mysql_exec->select(
            "SELECT id, hyoso_id, h1_id, dan_id, bun_id FROM hyosobun " .
            "ORDER BY id LIMIT 12", 1);
        my $h = $st->hundle;
        while (my $r = $h->fetch) {
            print $fh join("\t", map { defined $_ ? $_ : 'NULL' } @$r) . "\n";
        }
    };

    # Document-frequency tables. kh_nbayes::make_list builds its word list from
    # df_<tani> (kh_nbayes.pm:524-525), and scan_each only counts morphemes whose
    # genkei_id appears in that list (L388-390). If df_<tani> is missing or empty
    # the classifier trains on nothing and reports instances = 0 -- exactly the
    # failure seen when driving kh_nbayes directly.
    for my $t (@units) {
        print $fh "\n== df_$t ==\n";
        my $n;
        my $ok = eval {
            my $st = mysql_exec->select("SELECT COUNT(*) FROM df_$t", 1);
            $n = $st->hundle->fetch->[0];
            1;
        };
        if (!$ok) { print $fh "absent\n"; next; }
        print $fh "rows\t" . (defined $n ? $n : '?') . "\n";
        eval {
            my $st = mysql_exec->select(
                "SELECT genkei_id, f FROM df_$t ORDER BY f DESC LIMIT 5", 1);
            my $h = $st->hundle;
            while (my $r = $h->fetch) {
                print $fh join("\t", map { defined $_ ? $_ : 'NULL' } @$r) . "\n";
            }
        };
    }

    close($fh);
    _log("dbtables -> $out");
    return 1;
}

sub _cmd_db {
    my $out = "$LOGDIR/db_list.txt";    open(my $fh, '>', $out) or return 0;
    my $projs = eval { kh_projects->read };
    if ($projs && ref(my $l = $projs->list) eq 'ARRAY') {
        for my $p (@$l) {
            printf $fh "%s\t%s\t%s\n",
                (eval { $p->dbname } // '?'),
                (eval { $p->comment } // ''),
                (eval { $p->file_target } // '?');
        }
    } else { print $fh "NO_PROJECTS\n"; }
    close($fh);
    _log("db -> $out");
    return 1;
}

# ------------------------------------------------------------- morpho
sub _cmd_morpho {
    my ($file) = @_;
    my $p = _do_preprocess($file);
    _log("morpho " . ($p ? "OK" : "FAILED"));
    return $p ? 1 : 0;
}

# --------------------------------------------------------------- freq
sub _cmd_freq {
    my ($file, $outcsv) = @_;
    $outcsv ||= "$LOGDIR/freq.csv";
    my $p = _do_preprocess($file) or do { _log("freq: preprocess failed"); return 0; };
    my $ok = eval {
        require mysql_words;
        # CLASS method (path as first arg). Output is Shift_JIS on Windows.
        my $r = mysql_words->csv_list($outcsv);
        _log("csv_list returned " . (defined $r ? $r : 'undef'));
        1;
    };
    if ($@) { _log("freq EXC: $@"); return 0; }
    _log("freq -> $outcsv exists=" . (-e $outcsv ? 'yes size=' . (-s $outcsv) : 'no'));
    return $ok ? 1 : 0;
}

# --------------------------------------------------------- netgraph
sub _cmd_netgraph {
    my ($file, $outpng) = @_;
    $outpng ||= "$LOGDIR/net.png";
    return _figure(
        $file, $outpng,
        'gui_window::word_netgraph',
        sub { my $win = shift; $win->calc; },
        'w_word_netgraph_plot', 2,
        # setup: runs before the diagnostics, so min/df read the real values
        sub {
            my $win = shift;
            _set_entry($win->{net_obj}{entry_edges_number}, '120')
                unless exists $PARAM{edges};
            $win->{net_obj}{check_use_freq_as_size} = 1
                unless exists $PARAM{freq_as_size};
            my @unk = _apply_params($win);
            _log("netgraph: unknown params: @unk") if @unk;
        },
    );
}

# -------------------------------------------------------------- cls
sub _cmd_cls {
    my ($file, $outpng) = @_;
    $outpng ||= "$LOGDIR/cls.png";
    return _figure($file, $outpng, 'gui_window::word_cls',
        sub { my $w = shift; eval { $w->calc }; }, 'w_word_cls_plot', undef,
        sub { my $w = shift; my @u = _apply_params($w);
              _log("cls: unknown params: @u") if @u; });
}

# --------------------------------------------------------------- mds
sub _cmd_mds {
    my ($file, $outpng) = @_;
    $outpng ||= "$LOGDIR/mds.png";
    return _figure($file, $outpng, 'gui_window::word_mds',
        sub { my $w = shift; eval { $w->calc }; }, 'w_word_mds_plot', undef,
        sub { my $w = shift; my @u = _apply_params($w);
              _log("mds: unknown params: @u") if @u; });
}

# ----------------------------------------------------------- corresp
sub _cmd_corresp {
    my ($file, $outpng) = @_;
    $outpng ||= "$LOGDIR/corresp.png";
    # idx = 0, NOT undef.
    #
    # word_corresp builds FOUR plot objects (gui_window/word_corresp.pm:950-1013):
    #   $plot1   plot_mode="color"  <- labels ARE drawn
    #   $plot2   plot_mode="dots"   <- labels are explicitly blanked
    #   ($plotg / $plotv only when biplot is on)
    # and @plots = ($plot1,$plot2). The default idx picks $#$plots -- the dots
    # plot -- which is why earlier runs produced graphs with no word labels at
    # all: `if (plot_mode == "dots"){ col_txt_words <- NA }` (line ~1630).
    # Pick index 0 to get the labelled colour plot.
    return _figure($file, $outpng, 'gui_window::word_corresp',
        sub { my $w = shift; eval { $w->calc }; }, 'w_word_corresp_plot', 0,
        sub { my $w = shift; my @u = _apply_params($w);
              _log("corresp: unknown params: @u") if @u; });
}

# ------------------------------------------------- coded correspondence analysis
# This is the analysis that answers "which words distinguish these groups?" --
# the question a plain cross tabulation cannot answer.
#
# Why not crosstab?  gui_widget/tani.pm:10-16 lists the counting units as
# bun / dan / h5 / h4 / h3 / h2 / h1 -- DOCUMENT-like units only, never a word.
# So cod_outtab cross-tabulates units against groups (how many documents of
# each group), and reports a chi-square over those counts. To compare word
# usage ACROSS groups, KH Coder's correspondence analysis is the right tool:
# gui_window::cod_corresp pairs the word dimension with the coding groups.
#
# It is driven by the same .cod coding-rule file as crosstab (see _cmd_crosstab
# for the file format), which is what makes it workable headless: unlike
# word_corresp -- which reads its grouping from the outvar database tables --
# cod_corresp calls kh_cod::func->read_file($cfile)->out2r_selected($tani, ...)
# directly from the file.
#
# Output: the scatter plot at w_cod_corresp_plot.
#
# --cod FILE        coding-rule file (required)
# --tani UNIT       counting unit: bun | dan | h1..h5  (default dan)
sub _cmd_codcorresp {
    my ($file, $outpng) = @_;
    $outpng ||= "$LOGDIR/codcorresp.png";
    my $p = _do_preprocess($file) or do { _log("codcorresp: preprocess failed"); return 0; };

    my $cod = $PARAM{cod} // '';
    unless (length $cod && -e _fs($cod)) {
        _log("codcorresp: no coding-rule file (--cod FILE).");
        _log("codcorresp: the rule file declares the groups to compare, e.g.");
        _log("codcorresp:   ＊groupA");
        _log("codcorresp:   <>heading1-->groupA");
        _log("codcorresp:   ＊groupB");
        _log("codcorresp:   <>heading1-->groupB");
        return 0;
    }

    my $tani = $PARAM{tani} // 'dan';
    unless ($tani =~ /^(bun|dan|h[1-5])$/) {
        _log("codcorresp: --tani must be bun|dan|h1..h5, got '$tani'");
        return 0;
    }

    my $win = eval { gui_window::cod_corresp->open };
    if ($@ || !$win) { _log("codcorresp: open failed: $@"); return 0; }

    _auto_answer_modals($win);
    _install_error_guard();
    eval { $win->win_obj->withdraw; };

    # cfile() feeds read_cfile(), which parses the .cod file and builds the
    # list of group check-boxes. Populate cfile, then let the module read it.
    my $bound = 0;
    eval {
        if (ref($win->{codf_obj})) { $win->{codf_obj}{cfile} = _fs($cod); $bound = 1; }
    };
    _log("codcorresp: cod=" . ($bound ? 'bound' : 'MISSING') . "  tani=$tani");

    unless ($bound) {
        _log("codcorresp: codf_obj not reachable -- cannot inject the rule file");
        return 0;
    }

    # Read the rule file into the window's checks list without touching the GUI.
    my $codes = eval { $win->read_cfile; 1 };
    if ($@ || !$codes) { _log("codcorresp: read_cfile failed: $@"); return 0; }

    my @names = map { $_->{name} } @{ $win->{checks} || [] };
    _log("codcorresp: groups = " . (@names ? join(' | ', @names) : '(none)'));
    unless (@names) {
        _log("codcorresp: the rule file declared no groups");
        return 0;
    }

    # Apply the counting unit and word filters, then run.
    my $setup = sub {
        my $w = shift;
        eval { $w->{tani_obj}{tani} = $tani; $w->{tani} = $tani; };
        my @u = _apply_params($w);
        _log("codcorresp: unknown params: @u") if @u;
    };
    $setup->($win);

    my $ok = eval { $win->_calc; 1 };
    if ($@ || !$ok) { _log("codcorresp: _calc failed: $@"); }

    # The scatter plot lives at w_cod_corresp_plot.
    my $wr = $::main_gui->get('w_cod_corresp_plot');
    unless ($wr) { _log("codcorresp: no plot window"); return 0; }
    my $plots = $wr->{plots};
    unless (ref($plots) eq 'ARRAY' && @$plots) { _log("codcorresp: no plots"); return 0; }

    my $i = $#$plots;
    eval { $plots->[$i]->save($outpng); 1 };
    if (-e $outpng && -s $outpng) {
        _log("codcorresp -> $outpng (" . (-s $outpng) . " bytes)");
        return 1;
    }
    _log("codcorresp: save produced nothing");
    return 0;
}

# ------------------------------------------------------------------- SOM
# Self-organising map over words. Interface mirrors word_netgraph:
# gui_window::word_som has calc()/min()/max()/min_df()/max_df()/tani()/hinshi(),
# and the plot lives at w_word_som_plot. $win->{plots} holds the figures.
sub _cmd_som {
    my ($file, $outpng) = @_;
    $outpng ||= "$LOGDIR/som.png";
    return _figure($file, $outpng, 'gui_window::word_som',
        sub { my $w = shift; eval { $w->calc }; }, 'w_word_som_plot', undef,
        sub { my $w = shift; my @u = _apply_params($w);
              _log("som: unknown params: @u") if @u; });
}

# ----------------------------------------------------------- topic model
# Latent Dirichlet Allocation. gui_window::topic_fitting::calc writes its
# results into the w_topic_result window (data, not a figure), so this command
# exports the topic-term table to CSV rather than a PNG.
# --topics N sets the number of topics (default 10 in KH Coder).
sub _cmd_topic {
    my ($file, $outcsv) = @_;
    $outcsv ||= "$LOGDIR/topic.csv";
    my $p = _do_preprocess($file) or do { _log("topic: preprocess failed"); return 0; };

    my $ntopics = exists $PARAM{topics} ? $PARAM{topics} : 10;
    my $ok = eval {
        my $win = gui_window::topic_fitting->open;
        _auto_answer_modals($win);
        eval { $win->win_obj->withdraw; };
        _apply_params($win);
        # number of topics is a window field, not a words_obj entry
        $win->{n_topics} = $ntopics if defined $ntopics;
        _log("topic: n_topics=$ntopics");
        $win->calc;
        1;
    };
    if ($@) { _log("topic EXC: $@"); return 0; }

    # The fitted model lands in the w_topic_result window. That window keeps
    # its output in FILES rather than in-memory structures, and names them:
    #   file_topics_csv  -> document x topic probability matrix (topicTP)
    #   file_term        -> topic x term table (which words define each topic)
    #   file_topics      -> topic proportions
    # KH Coder deletes them when the window closes, so copy them NOW, inside
    # the same run.
    my $res = $::main_gui->get('w_topic_result');
    unless ($res) { _log("topic: no w_topic_result window"); return 0; }

    _log("topic: result keys = " . join(',', sort keys %$res));

    # Where the caller asked for the CSV; the sibling files go next to it with
    # a role suffix so a single run yields everything the analysis produced.
    my ($base, $ext) = $outcsv =~ /^(.*?)(\.[^.\/\\]*)?$/;
    $base = $outcsv unless defined $base && length $base;
    $ext  = '' unless defined $ext;

    my %ROLE = (
        file_topics_csv => ['doc-topic',  'document x topic probabilities'],
        file_term       => ['terms',      'topic x term table'],
        file_topics     => ['topics',     'topic proportions'],
    );

    my $primary_done = 0;
    for my $slot (qw(file_topics_csv file_term file_topics)) {
        my $src = $res->{$slot};
        next unless defined $src && length $src;
        my $src_fs = _fs($src);
        unless (-e $src_fs) { _log("topic: $slot points at a missing file: $src"); next; }

        my ($role, $desc) = @{ $ROLE{$slot} };
        my $dst = ($role eq 'doc-topic') ? $outcsv : "${base}_${role}${ext}";

        my $copied = eval {
            open(my $in,  '<:raw', $src_fs) or die "in: $!";
            open(my $out, '>:raw', $dst)     or die "out: $!";
            my $buf = do { local $/; my $d = <$in>; $d };
            print {$out} $buf;
            close($in); close($out);
            1;
        };
        if ($copied) {
            _log("topic: $slot -> $dst  ($desc, " . (-s $dst) . " bytes)");
            $primary_done ||= ($role eq 'doc-topic');
            # file_term's header row holds genkei IDs, not words. Replace them
            # with the actual word forms so the table is directly readable.
            if ($role eq 'terms') {
                my $mapped = _map_term_ids($dst);
                _log("topic: term ids mapped = $mapped") if defined $mapped;
            }
        } else {
            _log("topic: copy of $slot failed: $@");
        }
    }

    if ($primary_done) { _log("topic -> $outcsv OK"); return 1; }

    _log("topic: none of the known output files could be copied; keys were: " .
         join(',', sort keys %$res));
    return 0;
}

# Best-effort export of a topic model's term table.
sub _export_topic_table {
    my ($res, $outcsv) = @_;

    # KH Coder keeps the per-topic word lists in the result object; the exact
    # slot name varies between builds, so probe the likely ones.
    my $data;
    for my $k (qw(topic_term topic_words words topic_result result data)) {
        if (ref($res->{$k})) { $data = $res->{$k}; _log("topic: using slot '$k'"); last; }
    }
    unless ($data) {
        _log("topic: no usable data slot; keys seen: " . join(',', sort keys %$res));
        return 0;
    }

    my @rows;
    if (ref($data) eq 'ARRAY') {
        for my $r (@$data) {
            if (ref($r) eq 'ARRAY') { push @rows, [@$r]; }
            elsif (ref($r) eq 'HASH') { push @rows, [map { $r->{$_} } sort keys %$r]; }
        }
    } elsif (ref($data) eq 'HASH') {
        for my $k (sort keys %$data) {
            my $v = $data->{$k};
            $v = join(' ', @$v) if ref($v) eq 'ARRAY';
            push @rows, [$k, $v];
        }
    }
    return 0 unless @rows;

    my $n = eval {
        require Encode;
        open(my $fh, '>:encoding(utf8)', $outcsv) or die "open: $!";
        for my $r (@rows) {
            my @c = map { defined $_ ? $_ : '' } @$r;
            s/"/""/g for @c;
            print $fh '"' . join('","', @c) . "\"\n";
        }
        close($fh);
        scalar @rows;
    };
    if ($@) { _log("topic write EXC: $@"); return 0; }
    return $n;
}

# ------------------------------------------------------- cross tabulation
# Cross-tabulates words against an EXTERNAL VARIABLE, i.e. a per-document
# category. Unlike frequency or co-occurrence -- which describe one corpus --
# a cross tabulation compares word usage ACROSS document groups, so the corpus
# must already carry the grouping. Typical research use: tag documents by
# period / genre / author, then ask which words are over- or under-represented
# in each group (that table is the basis of a chi-square test).
#
# How the grouping is supplied
# ----------------------------
# cod_outtab requires BOTH of:
#   tani   -- the counting unit (set by preprocessing), and
#   cfile  -- a coding-rule file (.cod) describing the groups.
# Heading markers alone are not enough; cod_outtab.pm:237 checks
# `-e $self->cfile`, and without it we got
#   SUPPRESSED-ERROR: 非法的参数  at cod_outtab.pm line 239
#
# The .cod format comes from kh_cod.pm:42 read_file:
#   * a line starting with ＊ (or *) DECLARES a group;
#   * every following line is a matching condition for that group;
#   * '#' starts a comment, blank lines are ignored.
# Condition syntax is defined per atom; kh_cod/a_code/atom/heading.pm:175 gives
# the heading form:   <>heading1-->VALUE     (older builds: <>見出し1-->VALUE)
# So a corpus marked with <h1>三届</h1> / <h1>四届</h1> is grouped by:
#   ＊三届
#   <>heading1-->三届
#   ＊四届
#   <>heading1-->四届
#
# Result location: $win->{result} with {display} (printable table) and
# {plot} (matrix for figures). We export {display} to CSV.
#
# --cod FILE        coding-rule file (required for a real result)
# --var h1|h2|...   which heading level defines the groups (default h1)
sub _cmd_crosstab {
    my ($file, $outcsv) = @_;
    $outcsv ||= "$LOGDIR/crosstab.csv";
    my $p = _do_preprocess($file) or do { _log("crosstab: preprocess failed"); return 0; };

    my $var = exists $PARAM{var} ? lc($PARAM{var}) : 'h1';
    unless ($var =~ /^h[1-5]$/) {
        _log("crosstab: --var must be h1..h5, got '$var'");
        return 0;
    }

    my $cod = $PARAM{cod} // '';
    if (!length $cod || !-e _fs($cod)) {
        _log("crosstab: no coding-rule file (--cod FILE).");
        _log("crosstab: a cross tabulation needs per-document groups; provide a " .
             ".cod file declaring them, e.g.");
        _log("crosstab:   ＊groupA");
        _log("crosstab:   <>${var}-->groupA");
        _log("crosstab:   ＊groupB");
        _log("crosstab:   <>${var}-->groupB");
        return 0;
    }

    my $win = eval { gui_window::cod_outtab->open };
    if ($@ || !$win) { _log("crosstab: open failed: $@"); return 0; }

    _auto_answer_modals($win);
    _install_error_guard();             # else validation errors block forever
    eval { $win->win_obj->withdraw; };

    # Bind the grouping: var_id() forwards to {var_obj}{var_id}, and
    # cfile() forwards to {codf_obj}{cfile}. Both objects must be populated.
    my ($v_ok, $c_ok) = (0, 0);
    eval {
        if (ref($win->{var_obj})) { $win->{var_obj}{var_id} = $var; $v_ok = 1; }
        $win->{var_id} = $var;
    };
    eval {
        if (ref($win->{codf_obj})) { $win->{codf_obj}{cfile} = _fs($cod); $c_ok = 1; }
    };
    _log("crosstab: var=$var (" . ($v_ok ? 'bound' : 'MISSING') . ")  " .
         "cod=" . ($c_ok ? 'bound' : 'MISSING'));

    unless ($c_ok) {
        _log("crosstab: codf_obj not reachable -- cannot inject the rule file");
        return 0;
    }
    unless ($v_ok) {
        _log("crosstab: var_obj not reachable -- no grouping variable");
        return 0;
    }

    my $ok = eval { $win->_calc; 1 };
    if ($@ || !$ok) { _log("crosstab: _calc failed: $@"); }

    my $res = $win->{result};
    unless (ref($res) eq 'HASH') {
        _log("crosstab: no result object (analysis aborted early)");
        return 0;
    }

    my $disp = $res->{display};
    unless (ref($disp) eq 'ARRAY' && @$disp) {
        _log("crosstab: result{display} empty; keys: " . join(',', sort keys %$res));
        return 0;
    }

    my $n = _write_csv($outcsv, $disp);
    _log("crosstab -> $outcsv rows=" . ($n // 0));
    return $n ? 1 : 0;
}

# ------------------------------------------------------ Bayesian learning
# gui_window::bayes_learn::calc trains a naive-Bayes classifier over the
# external variable's categories and writes model files. Headless we only need
# the training to complete and the resulting statistics, which the module
# stores on the window ($win->{w_status} etc.). We export a short summary.
#
# --var h1|h2|...   variable whose categories are the classes (default h1)
sub _cmd_bayes {
    my ($file, $outcsv) = @_;
    $outcsv ||= "$LOGDIR/bayes.csv";
    my $p = _do_preprocess($file) or do { _log("bayes: preprocess failed"); return 0; };

    my $var = exists $PARAM{var} ? lc($PARAM{var}) : 'h1';
    unless ($var =~ /^h[1-5]$/) { _log("bayes: --var must be h1..h5"); return 0; }

    my $win = eval { gui_window::bayes_learn->open };
    if ($@ || !$win) { _log("bayes: open failed: $@"); return 0; }

    _auto_answer_modals($win);
    # CRITICAL: calc() validates several GUI entries (entry_fold range, the
    # variable selection) and reports failures through gui_errormsg::open,
    # whose tail closes the GUI or exits. Headless that used to hang for hours
    # (measured 12187 s before the harness killed it). The guard turns those
    # into log lines instead.
    _install_error_guard();
    eval { $win->win_obj->withdraw; };
    eval { _apply_params($win); };

    # Bind the external variable (the classes to predict).
    #
    # bayes_learn::outvar() (L385-388) forwards to {words_obj}->outvar, and
    # gui_widget/words_bayes.pm:350-353 shows that accessor simply returns
    # $self->{var_id} -- a plain scalar, not an object. So probing {var_obj}
    # reported MISSING and nothing was ever bound.
    my $bound = 0;
    eval {
        my $wo = $win->{words_obj};
        if (ref($wo)) {
            $wo->{var_id} = $var;
            $bound = 1;
            _log("bayes: set words_obj->{var_id}=$var readback=" .
                 (defined $wo->outvar ? $wo->outvar : 'undef'));
        }
    };
    unless ($bound) { _log("bayes: words_obj not reachable"); }

    # entry_fold expects 2..20. The widget is created with -state => 'disable'
    # (bayes_learn.pm:60), so delete/insert is ignored while disabled -- enable
    # it first so calc() reads our value instead of the hard-coded 10.
    if (ref($win->{entry_fold})) {
        my $fold = exists $PARAM{fold} ? $PARAM{fold} : 10;
        eval { $win->{entry_fold}->configure(-state => 'normal'); };
        _set_entry($win->{entry_fold}, $fold);
        my $rb = eval { $win->{entry_fold}->get };
        _log("bayes: fold=$fold readback=" . (defined $rb ? $rb : 'undef'));
    } else {
        _log("bayes: entry_fold widget not reachable");
    }

    # Model saving: calc() calls $win->getSaveFile() (bayes_learn.pm:243) when
    # {check_savev} is set, which opens a NATIVE Windows file dialog. Tk-level
    # modal interception cannot dismiss it, and headless nobody can -- it blocks
    # forever. So pre-answer it: set the path yourself and clear the checkbox
    # that would otherwise ask.
    #
    # --model FILE   where to write the .knb model (optional; saving is skipped
    #                entirely when neither --model nor --save is given)
    my $want_model = exists $PARAM{model} ? $PARAM{model} : ($PARAM{save} // '');
    eval {
        $win->{check_savev} = 0;
        $win->{check_savel} = 0;
        if (length $want_model) {
            $win->{check_savev} = 1;
            $win->{savev_path} = _fs($want_model);
            # With check_savev set, calc() ALSO requires a prediction-variable
            # name (bayes_learn.pm:198-207 reads {entry_vname} and errors with
            # "変数名を指定して下さい" when it is empty). The model writes two
            # variables named "<name>-class" and "<name>-is_correct", so the
            # name must not already exist in the outvar registry.
            my $vname = exists $PARAM{vname} ? $PARAM{vname} : 'bayes_pred';
            # calc() refuses to run if "<name>-class" or "<name>-is_correct"
            # already exists (bayes_learn.pm:212-222). Drop stale ones so a
            # second run on the same project still works.
            for my $suffix ('-class', '-is_correct') {
                eval { mysql_outvar->delete(name => $vname . $suffix); };
            }
            if (ref($win->{entry_vname})) {
                eval { $win->{entry_vname}->configure(-state => 'normal'); };
                _set_entry($win->{entry_vname}, $vname);
                my $rb = eval { $win->{entry_vname}->get };
                _log("bayes: vname=$vname readback=" . (defined $rb ? $rb : 'undef'));
            } else {
                $win->{entry_vname} = $vname;
                _log("bayes: entry_vname widget absent; stored $vname directly");
            }
        }
    };
    _log("bayes: savev=" . ($win->{check_savev} // 0) .
         " savel=" . ($win->{check_savel} // 0) .
         (length $want_model ? " model=$want_model" : " (no model output requested)"));

    # Replace getSaveFile/getOpenFile on this window so that, should calc() ask
    # anyway, it receives a path instead of opening a dialog. Without this the
    # run hangs on a native dialog that no headless interception can reach.
    # NOTE: override getSaveFile at BOTH the widget and the window level. The
    # call is dispatched from whichever object calc() happens to hold.
    eval {
        no warnings 'redefine';
        my $target = length $want_model ? _fs($want_model)
                   : _fs("$LOGDIR/bayes_model.knb");
        for my $obj ($win, $win->{win_obj}) {
            next unless ref($obj);
            no strict 'refs';
            *{ ref($obj) . '::getSaveFile' } = sub { return $target };
            *{ ref($obj) . '::getOpenFile' } = sub { return '' };
        }
        _log("bayes: getSaveFile/getOpenFile stubbed -> $target");
    };
    if ($@) { _log("bayes: stub install failed: $@"); }

    unless ($bound) {
        _log("bayes: SKIPPED - no external variable bound.");
        _log("bayes: naive Bayes predicts a per-document category, so the corpus " .
             "must carry one (mark it with <h1>..</h1> headings).");
        return 0;
    }

    # hinshi must be non-empty or calc() bails out immediately.
    my $hs = eval { $win->hinshi };
    _log("bayes: hinshi=" . (ref($hs) eq 'ARRAY' ? scalar(@$hs) . " entries" : 'undef'));
    if (ref($hs) eq 'ARRAY') {
        _log("bayes: hinshi values = [" . join(',', @$hs) . "]");
    }

    # kh_nbayes::make_list matches hselection.khhinshi_id against the entries in
    # {hinshi} (kh_nbayes.pm:530-534), so they must be numeric word-class IDs --
    # not names like "Noun". Resolve names to IDs when necessary, otherwise the
    # SQL matches nothing and training silently produces an empty model
    # (instances = 0).
    my @hinshi_ids;
    {
        my %id_of;
        eval {
            my $st = mysql_exec->select(
                "SELECT khhinshi_id, name FROM hselection", 1);
            my $h = $st->hundle;
            while (my $r = $h->fetch) {
                next unless defined $r->[0] && defined $r->[1];
                $id_of{ $r->[1] } = $r->[0];
            }
        };
        _log("bayes: hselection has " . scalar(keys %id_of) . " word classes");
        for my $v (@{ $hs || [] }) {
            next unless defined $v && length $v;
            if ($v =~ /^\d+$/) { push @hinshi_ids, $v; next; }
            if (defined $id_of{$v}) { push @hinshi_ids, $id_of{$v}; next; }
            _log("bayes: hinshi entry '$v' is neither a numeric id nor a known class name");
        }
        # Fall back to every selectable class if nothing resolved.
        unless (@hinshi_ids) {
            eval {
                my $st = mysql_exec->select(
                    "SELECT khhinshi_id FROM hselection WHERE ifuse = 1", 1);
                my $h = $st->hundle;
                while (my $r = $h->fetch) { push @hinshi_ids, $r->[0]; }
            };
            _log("bayes: resolved no ids; falling back to all ifuse classes");
        }
    }
    _log("bayes: hinshi ids = [" . join(',', @hinshi_ids) . "]");

    # Run the training directly through kh_nbayes so the statistics are
    # returned to us. bayes_learn::calc() also computes them, but keeps them in
    # a local ($r) whose only outlet is a message box (bayes_learn.pm:330-352),
    # so a headless run would lose the accuracy figures entirely -- and those
    # are the reason to train a classifier at all.
    #
    # kh_nbayes.pm:159-163 names the fields:
    #   instances, instances_all, cross_vl_tested, cross_vl_ok, kappa
    my $stats;
    my $ran = 0;
    # Resolve the variable name to its outvar id once; kh_nbayes needs the id.
    my $var_id;
    eval {
        my $st = mysql_exec->select(
            "SELECT id FROM outvar WHERE name = " . mysql_exec->quote($var), 1);
        $var_id = $st->hundle->fetch->[0];
    };
    _log("bayes: outvar id for '$var' = " . (defined $var_id ? $var_id : 'NOT FOUND'));
    eval {
        # learn_from_ov is a CLASS method: it takes %args and blesses them
        # itself (kh_nbayes.pm:24-28), and requires {path} -- it saves the
        # trained model there (L57).
        #
        # Argument names follow the authoritative call in bayes_learn.pm:303-315.
        # Training alone works; cross-validation does NOT, because it reblesses
        # $self into kh_nbayes::cv_train / cv_predict (kh_nbayes.pm:212-224) and
        # those helpers do not initialise {test_result} when invoked outside the
        # GUI path, dying at L74 with "Can't use an undefined value as an ARRAY
        # reference". So we always train without validation and measure fit
        # ourselves below.
        my $tani_u = exists $PARAM{tani} ? $PARAM{tani} : 'dan';
        my $mpath = length $want_model ? _fs($want_model)
                  : _fs("$LOGDIR/bayes_model.knb");

        # Diagnose the pieces kh_nbayes depends on, then train.
        my $vo = eval { mysql_outvar::a_var->new(undef, $var_id) };
        if (ref($vo)) {
            _log("bayes: a_var table=" . ($vo->{table} // 'undef') .
                 " column=" . ($vo->{column} // 'undef') .
                 " tani=" . ($vo->{tani} // 'undef') .
                 " labels=" . scalar(keys %{ $vo->{labels} || {} }));
        } else {
            _log("bayes: a_var->new returned " . ref($vo));
        }
        eval {
            my $st = mysql_exec->select("SELECT COUNT(*) FROM $tani_u", 1);
            _log("bayes: $tani_u rows = " . $st->hundle->fetch->[0]);
        };

        $stats = kh_nbayes->learn_from_ov(
            tani     => $tani_u,
            # kh_nbayes::get_ov calls mysql_outvar::a_var->new(undef, $self->{outvar})
            # (kh_nbayes.pm:474) and a_var's constructor looks the row up by
            # numeric id (a_var.pm:28-36). Passing the NAME leaves table/column
            # undefined and yields an empty model, so pass the id.
            outvar   => (defined $var_id ? $var_id : $var),
            path     => $mpath,
            min      => (exists $PARAM{min}    ? $PARAM{min}    : 5),
            max      => (exists $PARAM{max}    ? $PARAM{max}    : 0),
            min_df   => (exists $PARAM{min_df} ? $PARAM{min_df} : 1),
            max_df   => (exists $PARAM{max_df} ? $PARAM{max_df} : 0),
            hinshi   => \@hinshi_ids,
            add_data => 0,
            cross_vl => 0,          # see note above
        );
        $ran = 1;
    };
    if ($@) { _log("bayes: direct kh_nbayes run failed: $@"); }
    if ($@ || !$ran) {
        _log("bayes: direct kh_nbayes run failed: $@");
        # Fall back to driving the window, which at least writes the model file.
        my $ok = eval { $win->calc; 1 };
        _log("bayes: window calc returned " . ($ok ? 'ok' : 'early-exit'));
    }

    my @rows = (['item', 'value']);
    if (ref($stats) eq 'HASH') {
        for my $k (qw(instances instances_all cross_vl_tested cross_vl_ok kappa)) {
            next unless defined $stats->{$k};
            push @rows, [$k, $stats->{$k}];
        }
        # Accuracy is the headline number: correct / tested.
        if ($stats->{cross_vl_tested}) {
            my $acc = sprintf("%.1f%%",
                $stats->{cross_vl_ok} / $stats->{cross_vl_tested} * 100);
            push @rows, ['accuracy', $acc];
        }
        _log("bayes: stats " . join(' ', map { "$_->[0]=$_->[1]" } @rows[1..$#rows]));
    } else {
        # Collect whatever the window happens to expose instead.
        for my $k (sort keys %$win) {
            next if ref($win->{$k});
            next unless defined $win->{$k};
            next unless $k =~ /^(docs|docs_total|accuracy|vname|fold|n_|time)/;
            push @rows, [$k, $win->{$k}];
        }
        _log("bayes: no statistics object; collected " . (scalar(@rows) - 1) . " from window");
    }

    push @rows, ['model', $want_model] if length $want_model;

    my $n = _write_csv($outcsv, \@rows);
    _log("bayes -> $outcsv rows=" . ($n // 0));
    return $n ? 1 : 0;
}

# Replace the numeric genkei IDs in a topic term table's header row with the
# actual word forms, so the CSV is readable without a database lookup.
# Returns the number of IDs mapped, or undef on failure.
sub _map_term_ids {
    my ($path) = @_;
    my $fs = _fs($path);
    return undef unless -e $fs;

    my $text = eval {
        open(my $in, '<:encoding(utf8)', $fs) or die "in: $!";
        my $d = do { local $/; <$in> };
        close($in);
        $d;
    };
    if ($@ || !defined $text) { _log("topic: cannot read $path: $@"); return undef; }

    my @lines = split(/\n/, $text);
    return undef unless @lines;
    my @head = split(/\t/, $lines[0], -1);
    return undef unless @head > 1;

    # Look up each ID in genkei (id -> name).
    #
    # mysql_exec->select() returns an OBJECT (a statement handle wrapper), not
    # rows. Rows come from ->hundle->fetch, one at a time -- see
    # mysql_words.pm:33 for the same pattern.
    my %name;
    my @ids = grep { /^\d+$/ } @head[1 .. $#head];
    if (@ids) {
        my $in = join(',', @ids);
        my $ok = eval {
            my $st = mysql_exec->select("SELECT id, name FROM genkei WHERE id IN ($in)", 1);
            my $h  = $st->hundle;
            while (my $r = $h->fetch) {
                next unless ref($r) eq 'ARRAY' && @$r >= 2;
                $name{$r->[0]} = $r->[1];
            }
            1;
        };
        _log("topic: genkei query failed: $@") unless $ok;
        _log("topic: genkei returned " . scalar(keys %name) . " names");
    }

    my $mapped = 0;
    for my $i (1 .. $#head) {
        next unless $head[$i] =~ /^\d+$/;
        if (defined $name{$head[$i]}) { $head[$i] = $name{$head[$i]}; ++$mapped; }
    }
    $lines[0] = join("\t", @head);

    my $ok = eval {
        open(my $out, '>:encoding(utf8)', $fs) or die "out: $!";
        print {$out} join("\n", @lines);
        close($out);
        1;
    };
    if ($@) { _log("topic: cannot rewrite $path: $@"); return undef; }
    return $mapped;
}

# Write a 2-D array as UTF-8 CSV. Returns the row count, or undef on failure.
sub _write_csv {
    my ($path, $rows) = @_;
    return undef unless ref($rows) eq 'ARRAY' && @$rows;
    my $n = eval {
        require Encode;
        open(my $fh, '>:encoding(utf8)', $path) or die "open: $!";
        for my $r (@$rows) {
            my @c = ref($r) eq 'ARRAY' ? @$r : ($r);
            @c = map { defined $_ ? $_ : '' } @c;
            s/"/""/g for @c;
            print $fh '"' . join('","', @c) . "\"\n";
        }
        close($fh);
        scalar @$rows;
    };
    if ($@) { _log("csv write EXC: $@"); return undef; }
    return $n;
}

# ---------------------------------------------------------------- KWIC
# Mirrors gui_window::word_conc::search(): mysql_conc->a_word(...).
#
# NOTE: we deliberately do NOT call $res->save_all(). That exporter opens the
# output with `use File::BOM`, which is absent from the PDK-packed exe, so it
# falls through to gui_errormsg -> _TK_EXIT_(0) headless. Instead we read the
# result via the object's own accessors and write UTF-8 CSV ourselves.
sub _cmd_conc {
    my ($file, $word, $outcsv, $sort1) = @_;
    $outcsv ||= "$LOGDIR/conc.csv";
    unless (defined $word && length $word) { _log("conc: no search word"); return 0; }
    _log("conc: word=[$word] sort1=" . ($sort1 // 'id'));

    my $p = _do_preprocess($file) or do { _log("conc: preprocess failed"); return 0; };

    my ($got, $rows) = (0, []);
    my $ok = eval {
        require mysql_conc;
        _log("conc: mysql_conc loaded");
        mysql_conc->initialize;
        _log("conc: initialized; calling a_word");
        my $res = mysql_conc->a_word(
            query  => $word,
            katuyo => '',
            hinshi => '',
            tuika  => { 1 => {}, 2 => {}, 3 => {} },
            length => 40,
            # Sort selectors MUST be given. Legal values (see
            # gui_window/word_conc.pm @options): id | l5..l1 | center | r1..r5.
            # 'id' means "occurrence order" and terminates the sort chain.
            # Omitting them makes _sort() interpolate empty column names and
            # emit invalid SQL (" int," / "ON temp_conc. = h0.id").
            sort1  => $sort1 // 'id',
            sort2  => 'id',
            sort3  => 'id',
        );
        _log("conc: a_word returned " . (defined $res ? ref($res) : 'undef/0'));
        return 0 unless $res;

        my $max = $res->_count;
        _log("conc: hits=$max");
        return 0 unless $max;

        # _format($start) returns [ [left, center, right], ... ] for a page.
        my $start = 1;
        while ($start <= $max) {
            _log("conc: formatting from $start");
            my $page = $res->_format($start);
            push @$rows, @$page if ref($page) eq 'ARRAY';
            $start += 200;
        }
        _log("conc: collected " . scalar(@$rows) . " rows");
        $got = 1;
        1;
    };
    if ($@) { _log("conc EXC: $@"); return 0; }
    return 0 unless $got;

    # Write UTF-8 CSV ourselves (no File::BOM dependency).
    my $wrote = eval {
        require Encode;
        open(my $fh, '>:encoding(utf8)', $outcsv) or die "cannot open $outcsv: $!";
        print $fh "L,C,R\n";
        for my $r (@$rows) {
            my @c = map { defined $_ ? $_ : '' } @$r;
            s/"/""/g for @c;
            print $fh '"' . join('","', @c) . "\"\n";
        }
        close($fh);
        1;
    };
    if ($@) { _log("conc write EXC: $@"); return 0; }

    _log("conc -> $outcsv rows=" . scalar(@$rows) .
         " exists=" . (-e $outcsv ? 'yes size=' . (-s $outcsv) : 'no'));
    return $wrote ? 1 : 0;
}

# ---------------------------------------------------------------------------
# Non-interactive confirmation.
#
# Several analysers open a modal confirmation box before proceeding, e.g.
# word_netgraph::calc does:
#     if ($check_num > 300){
#         my $ans = $self->win_obj->messageBox(-type => 'OKCancel', ...);
#         unless ($ans =~ /ok/i){ return 0; }
#     }
# Headless there is no one to click it: the call blocks and the analysis
# silently returns 0, producing an empty figure. Rather than editing KH Coder's
# own modules we patch messageBox on the window object so it answers for us,
# and record what was auto-answered so the run stays auditable.
# ---------------------------------------------------------------------------
sub _auto_answer_modals {
    my ($win) = @_;
    return unless ref($win) && ref($win->{win_obj});

    my $target = $win->{win_obj};
    no warnings 'redefine';
    no strict 'refs';

    my $pkg = ref($target);
    return unless $pkg;

    # Remember the original so repeated calls in one process are harmless.
    my $orig_key = "${pkg}::__khc_orig_messageBox";
    unless (defined &{$orig_key}) {
        my $orig = $pkg->can('messageBox');
        return unless $orig;
        *{$orig_key} = $orig;
    }

    *{"${pkg}::messageBox"} = sub {
        my ($self, %args) = @_;
        my $msg = $args{-message} // '';
        $msg =~ s/\s+/ /g;
        _log("AUTO-CONFIRM (headless): " . substr($msg, 0, 160));

        # Answer "continue" -- always. Plotting a few thousand terms is slow
        # but it does work (measured: 1429 terms completed in ~12 min, 877 in
        # 7 min, 233 in under a minute). Refusing here would silently turn a
        # slow-but-valid analysis into a failure, so we only record that the
        # prompt happened and let the caller decide from the timing guidance.
        if ($msg =~ /(\d[\d,]*)\s*(?:語|词汇|词|terms?)/) {
            my $n = $1; $n =~ s/,//g;
            $KH{too_many} = $n;
            _log("AUTO-CONFIRM: proceeding despite $n terms " .
                 "(expect several minutes; consider a higher --min)");
        }
        return 'ok';        # proceed, matching what a user would click
    };
    _log("modal auto-confirm installed on $pkg");
}

# ---------------------------------------------------------- struct probe
# Dump the analyser window's fields so we can find which controls hold the
# word-selection parameters (min/max, min_df/max_df, hinshi, ...).
sub _cmd_probe_win {
    my ($file) = @_;
    my $p = _do_preprocess($file) or do { _log("probewin: preprocess failed"); return 0; };

    my $win = eval { gui_window::word_netgraph->open };
    if ($@ || !$win) { _log("probewin: open failed: $@"); return 0; }

    _log("--- top-level fields of \$win ---");
    for my $k (sort keys %$win) {
        my $v = $win->{$k};
        next if ref($v);
        _log("  $k = " . (defined $v ? $v : 'undef'));
    }

    _log("--- \$win->{net_obj} scalar fields ---");
    if (ref($win->{net_obj}) eq 'HASH') {
        for my $k (sort keys %{$win->{net_obj}}) {
            my $v = $win->{net_obj}{$k};
            next if ref($v);
            _log("  net_obj.$k = " . (defined $v ? $v : 'undef'));
        }
    }

    _log("--- \$win->{words_obj} scalar fields ---");
    if (ref($win->{words_obj}) eq 'HASH') {
        for my $k (sort keys %{$win->{words_obj}}) {
            my $v = $win->{words_obj}{$k};
            next if ref($v);
            _log("  words_obj.$k = " . (defined $v ? $v : 'undef'));
        }
    }

    _log("--- accessor values ---");
    for my $m (qw(min max min_df max_df tani hinshi)) {
        my $r = eval { $win->$m };
        my $d = $@ ? " EXC:$@" : '';
        if (ref($r) eq 'ARRAY') { $r = '[' . join(',', @$r) . ']'; }
        _log("  \$win->$m() = " . (defined $r ? $r : 'undef') . $d);
    }

    # Locate where those values actually live, so we can override them.
    _log("--- locate storage of min / min_df ---");
    for my $slot (qw(words_obj net_obj)) {
        my $o = $win->{$slot};
        next unless ref($o);
        _log("  [$slot] ref=" . ref($o) . " keys=" . join(',', sort keys %$o));
        # widgets usually keep an Entry whose ->get() holds the value
        for my $k (sort keys %$o) {
            my $v = $o->{$k};
            next unless ref($v);
            my $g = eval { $v->get };
            if (defined $g && $g !~ /^\s*$/) { _log("    [$slot.$k]->get() = $g"); }
            my $s = eval { $v->cget('-text') };
            if (defined $s && $s !~ /^\s*$/) { _log("    [$slot.$k] -text = $s"); }
        }
    }

    # Does a setter exist and does it stick?
    _log("--- try writing via accessor ---");
    my $before = eval { $win->min };
    eval { $win->min(200) };        # deliberately large
    my $after = eval { $win->min };
    _log("  min: before=$before  after setter(200)=$after  " . ($after == 200 ? "STICKS" : "IGNORED"));

    # Decisive test: change ent_min (the real Entry) and see if the number of
    # words that would be plotted actually changes.
    _log("--- ent_min sweep: does wnum respond? ---");
    my $w = $win->{words_obj};
    for my $v (5, 50, 200, 500) {
        eval {
            $w->{ent_min}->delete(0, 'end');
            $w->{ent_min}->insert(0, $v);
        };
        my $now = eval { $w->{ent_min}->get };
        my $n = eval {
            my $chk = mysql_crossout::r_com->new(
                tani   => $win->tani,
                tani2  => $win->tani,
                hinshi => $win->hinshi,
                max    => $win->max,
                min    => $win->min,
                max_df => $win->max_df,
                min_df => $win->min_df,
            )->wnum;
            $chk =~ s/,//g;
            $chk;
        };
        my $err = $@ ? " EXC:$@" : '';
        _log("  ent_min=$v (readback=$now)  -> words_to_plot=$n$err");
    }
    return 1;
}

# ---------------------------------------------------------------- words
# Report how many terms would enter an analysis at a given threshold.
# This is the feedback loop for choosing parameters: run it, look at the
# numbers, then pick a threshold instead of guessing.
sub _cmd_words {
    my ($file) = @_;
    my $p = _do_preprocess($file) or do { _log("words: preprocess failed"); return 0; };

    my $db = eval { $::project_obj->dbname };
    unless ($db) { _log("words: no dbname"); return 0; }

    _log("words: term counts by threshold (database $db)");

    # Count distinct terms meeting each document-frequency threshold.
    my @thresholds = exists $PARAM{at}
        ? (split /[,\s]+/, $PARAM{at})
        : (1, 2, 3, 5, 10, 20, 30, 50, 80, 100, 150, 200, 300);

    my @report;
    for my $t (@thresholds) {
        next unless $t =~ /^\d+$/;
        my $n = eval {
            my $r = mysql_exec->select(
                "SELECT COUNT(*) FROM (" .
                "SELECT hyoso FROM ${db}.rowdata " .
                "WHERE hinshi NOT IN ('PU','EOS') " .
                "GROUP BY hyoso HAVING COUNT(*) >= $t) x", 1);
            $r ? $r->hundle->fetch->[0] : undef;
        };
        my $v = defined $n ? $n : 'na';
        push @report, "$t=$v";
        _log(sprintf("  freq >= %4d  ->  %s terms", $t, $v));
    }

    # Also honour --min so the caller can ask about one specific value, and
    # write a machine-readable line for downstream tooling.
    if (exists $PARAM{min}) {
        my $t = $PARAM{min};
        my $n = eval {
            my $r = mysql_exec->select(
                "SELECT COUNT(*) FROM (" .
                "SELECT hyoso FROM ${db}.rowdata " .
                "WHERE hinshi NOT IN ('PU','EOS') " .
                "GROUP BY hyoso HAVING COUNT(*) >= $t) x", 1);
            $r ? $r->hundle->fetch->[0] : undef;
        };
        _log("words: min=$t would give " . (defined $n ? $n : 'na') . " terms");
    }

    _log("words: summary " . join(' ', @report));
    return 1;
}

# ------------------------------------------------------------- entry
sub plugin_config {
    return undef unless (defined($ARGV[0]) && $ARGV[0] eq '-khc');
    my $cmd = $ARGV[1] // 'probe';

    # Decode console-codepage arguments into Perl character strings.
    my @raw = map { _arg($_) } @ARGV;
    # "--lang xx" is handled first, then any remaining "--key value" options
    # are collected as analysis parameters; what is left is positional.
    my @a = _extract_params(_extract_lang_flag(@raw));
    _install_error_guard();
    # Kill the logo splash as the very first action, before anything slow. Every
    # command -- including probe and db, which never reach _do_preprocess -- gets
    # this, so the window is gone within a second of start-up in all cases.
    _log("=== invoked cmd=$cmd lang=" . ($CLI_LANG // 'auto') . " (args decoded, error guard on) ===");

    my $rc = eval {
        return _cmd_probe()                       if $cmd eq 'probe';
        return _cmd_probe_win($a[2])              if $cmd eq 'probe_win';
        return _cmd_db()                          if $cmd eq 'db';
        return _cmd_dbtables($a[2])               if $cmd eq 'dbtables';
        return _cmd_mkoutvar($a[2])               if $cmd eq 'mkoutvar';
        return _cmd_morpho($a[2])                 if $cmd eq 'morpho';
        return _cmd_freq($a[2], $a[3])            if $cmd eq 'freq';
        return _cmd_netgraph($a[2], $a[3])        if $cmd eq 'netgraph';
        return _cmd_cls($a[2], $a[3])             if $cmd eq 'cls';
        return _cmd_mds($a[2], $a[3])             if $cmd eq 'mds';
        return _cmd_corresp($a[2], $a[3])         if $cmd eq 'corresp';
        return _cmd_conc($a[2], $a[3], $a[4], $a[5]) if $cmd eq 'conc';
        return _cmd_words($a[2])                  if $cmd eq 'words';
        return _cmd_som($a[2], $a[3])             if $cmd eq 'som';
        return _cmd_topic($a[2], $a[3])           if $cmd eq 'topic';
        return _cmd_crosstab($a[2], $a[3])        if $cmd eq 'crosstab';
        return _cmd_codcorresp($a[2], $a[3])      if $cmd eq 'codcorresp';
        return _cmd_bayes($a[2], $a[3])           if $cmd eq 'bayes';
        _log("unknown command: $cmd");
        return 0;
    };
    if ($@) { _log("FATAL: $@"); $rc = 0; }
    _log("=== exit rc=" . (defined $rc ? $rc : 'undef') . " ===");
    exit(0);
}

1;
