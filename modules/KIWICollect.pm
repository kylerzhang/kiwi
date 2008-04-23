#================
# FILE          : KIWICollect.pm
#----------------
# PROJECT       : OpenSUSE Build-Service
# COPYRIGHT     : (c) 2006 SUSE LINUX Products GmbH, Germany
#               :
# AUTHOR        : Jan-Christoph Bornschlegel <jcbornschlegel@suse.de>
#               :
# BELONGS TO    : Operating System images
#               :
# DESCRIPTION   : This module collects sources from various source trees
#               : and creates one base directory structure which can be
#               : used as base for CD creation
#               :
#               :
# STATUS        : Development
#----------------
package KIWICollect;

#==========================================
# Modules
#------------------------------------------
use strict;
use KIWIXML;
use KIWIUtil;
use KIWIRPMQ;

use File::Find;
use File::Path;

# remove if not longer necessary:
use Data::Dumper;

#==========================================
# Members
#------------------------------------------
# m_kiwi:
#   Instance of KIWILog for feedback
# m_xml:
#   Instance of KIWIXML for retrieving the data contained
#   in the config.xml file
# m_util:
#   Instance of KIWIUtil which provides several methods to
#   analyse directories locally and via http(s)
# m_basedir:
#   Directory under which everything is accumulated
#   (aka downloaded/copied to)
# m_packages:
#   list of all packages from the config file
#   (...)
#
# ---BAUSTELLE---

#==========================================
# Constructor
#------------------------------------------
sub new {
  # ...
  # Create a new KIWICollect object which is used to create a
  # consistent package directory from various source trees
  # ---
  #==========================================
  # Object setup
  #------------------------------------------
  my $class = shift;

  my $this  = {
    m_archlist	    => undef,
    m_srclist	    => undef,
    m_basedir	    => undef,
    m_repos	    => undef,
    m_xml	    => undef,
    m_util	    => undef,
    m_kiwi	    => undef,
    m_packages	    => undef,
    m_metapackages  => undef,
    m_metafiles	    => undef,
    m_browser	    => undef,
    m_logger	    => undef,
    m_fpacks	    => [],
    m_fmpacks	    => [],
    m_debug	    => undef,
    #m_fpath => {
    #  'intel' => ['i686', 'i586', 'i486', 'i386', 'noarch'],
    #  'amd'   => ['x86_64', 'noarch'],
    #  'ppc64' => ['ppc64', 'noarch'],
    #  'ppc'   => ['ppc', 'noarch'],
    #  'hp'    => ['hppa', 'noarch'],
    #  'ia'    => ['ia64', 'noarch'],
    #  's390'  => ['s390x', 's390', 'noarch'],
    #  #'none'  => ['noarch'],
    #  },
  };

  bless $this, $class;

  #==========================================
  # Module Parameters
  #------------------------------------------
  $this->{m_kiwi}     = shift;
  $this->{m_xml}      = shift;
  $this->{m_basedir}  = shift;
  $this->{m_debug}    = shift || 0;

  if( !(defined($this->{m_xml})
	and defined($this->{m_basedir})
	and defined($this->{m_kiwi})))
  {
    return undef;
  }

  $this->Init();

  # create some default directories:
  foreach my $n($this->getMediaNumbers()) {
    $this->{m_dirlist}->{"$this->{m_basedir}/$this->{m_prodinfo}->{MEDIUM_NAME}$n"} = 1;
    $this->{m_dirlist}->{"$this->{m_basedir}/$this->{m_prodinfo}->{MEDIUM_NAME}$n/suse"} = 1;
  }
  # medium number 1 MUST exist, because it's the default for
  # packages that don't specify their own medium number
  $this->{m_dirlist}->{"$this->{m_basedir}/$this->{m_prodinfo}->{MEDIUM_NAME}1/suse"} = 1;
  $this->{m_dirlist}->{"$this->{m_basedir}/$this->{m_prodinfo}->{MEDIUM_NAME}1/script"} = 1;
  $this->{m_dirlist}->{"$this->{m_basedir}/$this->{m_prodinfo}->{MEDIUM_NAME}1/temp"} = 1;
  $this->createDirectoryStructure();

  return $this;
}
# /constructor



#==========================================
# Init
#------------------------------------------
# does everything that needs to be done but
# makes no sense in the constructor:
# - setup the logger for repo creation stuff
# - create Utility object
# - retrieve lists of required packages
# - dump them (optional)
# - create LWP client object
# - calls "normaliseDirname for each repo's sourcedirs
#   (stores the result in repo->[name]->'basedir')
# - creates the respective basedir beneath the current dir
#   [FIXME: use global base here to avoid problems]
# - creates path list for each repo
#   (stored in repos->[name]->'srcdirs')
# - initialises failed packs lists (empty)
#==========================================
sub Init
{
  my $this = shift;
  my $debug = shift || 0;

  # create second logger object to log only the data relevant
  # for repository creation:
  $this->{m_logger} = new KIWILog("tiny");#$this->{m_kiwi};
  $this->{m_logger}->setLogHumanReadable();
  $this->{m_logger}->setLogFile("$this->{m_basedir}/packages.log");
  $this->{m_kiwi}->info("Logging repository specific data to file $this->{m_basedir}/packages.log");

  $this->{m_util} = new KIWIUtil($this->{m_logger});

  if($this->{m_basedir} !~ m{.*/$}) {
    $this->{m_basedir} =~ s{(.*)$}{$1/};
  }

  # retrieve data from xml file:
  ## packages list (regular packages)
  %{$this->{m_packages}}      = $this->{m_xml}->getInstSourcePackageList();
  if($this->{m_debug}) {
    open(DUMP, ">", "$this->{m_basedir}/packages.dump.pl");
    print DUMP Dumper($this->{m_packages});
    close(DUMP);
  }

  ## architectures information (hash with name|desrc|next, next may be 0 which means "no fallback")
  %{$this->{m_archlist}}      = $this->{m_xml}->getInstSourceArchList();
  if($this->{m_debug}) {
    open(DUMP, ">", "$this->{m_basedir}/archlist.dump.pl");
    print DUMP Dumper($this->{m_archlist});
    close(DUMP);
  }

  ## repository information
  %{$this->{m_repos}}	      = $this->{m_xml}->getInstSourceRepository();
  if($this->{m_debug}) {
    open(DUMP, ">", "$this->{m_basedir}/repos.dump.pl");
    print DUMP Dumper($this->{m_repos});
    close(DUMP);
  }

  @{$this->{m_srclist}}	      = keys %{$this->{m_repos}}; # do we really need this optimisation?
  ## package list (metapackages with extra effort by scripts)
  %{$this->{m_metapackages}}  = $this->{m_xml}->getInstSourceMetaPackageList();
  if($this->{m_debug}) {
    open(DUMP, ">", "$this->{m_basedir}/metapackages.dump.pl");
    print DUMP Dumper($this->{m_metapackages});
    close(DUMP);
  }

  ## metafiles: different handling
  %{$this->{m_metafiles}}     = $this->{m_xml}->getInstSourceMetaFiles();
  if($this->{m_debug}) {
    open(DUMP, ">", "$this->{m_basedir}/metafiles.dump.pl");
    print DUMP Dumper($this->{m_metafiles});
    close(DUMP);
  }

  ## info about requirements for chroot env to run metadata scripts
  @{$this->{m_chroot}}	      = $this->{m_xml}->getInstSourceChrootList();
  if($this->{m_debug}) {
    open(DUMP, ">", "$this->{m_basedir}/chroot.dump.pl");
    print DUMP Dumper($this->{m_chroot});
    close(DUMP);
  }

  ## hash of varname=value pairs necessary for scripts (ENV)
  %{$this->{m_prodinfo}}      = $this->{m_xml}->getInstSourceProductInfo();
  if($this->{m_debug}) {
    open(DUMP, ">", "$this->{m_basedir}/prodinfo.dump.pl");
    print DUMP Dumper($this->{m_prodinfo});
    close(DUMP);
  }


  ### THIS IS ONLY FIRST SHOT! TODO FIXME
  ## set env vars according to "productinfo" elements:
  while(my ($name,$value) = each(%{$this->{m_prodinfo}})) {
    $ENV{$name} = $value;
  }

  $this->{m_united} = "$this->{m_basedir}/main";
  $this->{m_basesubdir} = "$this->{m_united}/$this->{m_prodinfo}->{MEDIUM_NAME}1/suse";
  $this->{m_dirlist}->{"$this->{m_united}"} = 1;
  $this->{m_dirlist}->{"$this->{m_basesubdir}"} = 1;

  # for debugging:
  $this->dumpPackageList("$this->{m_basedir}/packagelist.txt");

  $this->{m_browser} = new LWP::UserAgent;

  ## second level initialisation done, now start work:
  $this->{m_logger}->info("");
  $this->{m_logger}->info("STEP 0 (initialise) -- Examining repository structure");
  $this->{m_logger}->info("STEP 0.1 (initialise) -- Create local paths");

  # create local directories as download targets. Normalising special chars (slash, dot, ...) by replacing with second param.
  foreach my $r(keys(%{$this->{m_repos}})) {
    $this->{m_repos}->{$r}->{'basedir'} = $this->{m_basedir}.$this->normaliseDirname($this->{m_repos}->{$r}->{'source'}, '-');

    $this->{m_dirlist}->{"$this->{m_repos}->{$r}->{'basedir'}"} = 1;

    $this->{m_logger}->info("STEP 1.2 -- Expand path names for all repositories");
    $this->{m_repos}->{$r}->{'source'} =~ s{(.*)/$}{$1};  # strip off trailing slash in each repo (robust++)
    my @tmp;

    # splitPath scans the URLs for valid directories no matter if they are local/remote (currently http(s), file and opensuse://
    # are allowed. The list of directories is stored in the tmp list (param 1), the 4th param pattern determines the depth
    # for the scan.
    # TODO verify if a common interface with scanner/redirector code is possible!
    if(not defined($this->{m_util}->splitPath(\@tmp, $this->{m_browser}, $this->{m_repos}->{$r}->{'source'}, "/.*/.*/", 0))) {
      $this->{m_kiwi}->warning("KIWICollect::new: KIWIUtil::splitPath returned undef!");
    }

    foreach my $dir(@tmp) {
      $dir = substr($dir, length($this->{m_repos}->{$r}->{'source'}));
      $dir = "$dir/";
    }

    my $tmp = @tmp;
    my %tmp = map { $_, undef } @tmp;
    if($tmp != 0) {
      $this->{m_repos}->{$r}->{'srcdirs'} = \%tmp;
    }
    else {
      $this->{m_repos}->{$r}->{'srcdirs'} = undef;
    }
  }
}
# /Init



#==========================================
# normaliseDirname
#------------------------------------------
# Create a name without slashes, colons et cetera, replace
# all funny characters by dots and thus create a string which
# can be used as directory name.
#------------------------------------------
# Parameters:
#   $this - reference to the object for which it is called
#   $dirname - the RAW name, in the usual case an URL
#   $sepchar - the character that shall be used for token separation
#	Defaults to `.' if omitted.
# Returns:
#   a string consisting of letter tokens separated by dots
#------------------------------------------
sub normaliseDirname
{
  my $this    = shift;
  my $dirname = shift;
  my $sepchar = shift;
  if(!defined($sepchar)
      or $sepchar =~ m{[\w\s:\(\)\[\]\$]}) {
    $sepchar = "-";
  }

  # remove leading protocol name:
  $dirname =~ s{^(http|https|file|ftp)[:]/*}{};
  # remove some annoying chars:
  $dirname =~ s{[\/:]}{$sepchar}g;
  # remove double sep chars:
  $dirname =~ s{[$sepchar]+}{$sepchar}g;
  # remove leading and trailing sepchars:
  $dirname =~ s{^[$sepchar]}{}g;
  $dirname =~ s{[$sepchar]$}{}g;
  # remove trailing slashes:
  $dirname =~ s{/+$}{}g;

  return $dirname;
}
# /normaliseDirname




#==========================================
# mainTask
#------------------------------------------
# After initialisation by the constructor the repositories
# have to be processed and a lot of things will have to be
# done. So this method will grow a lot doing all this by
# invoking specialised submethods
#------------------------------------------
# Parameters
# $this - reference to the object for which it is called
# nothing more - everything else must be handled through
# member data and accessible methods. No dirty tricks *please*
#------------------------------------------
sub mainTask
{
  my $this = shift;
  my $retval = undef;

  return $retval if not defined($this);

  if(defined($this->collectPackages())) {
    $retval = 0;
  }

  return $retval;
}
# /mainTask




#==========================================
# getPackagesList
#------------------------------------------
sub getPackagesList
{
  my $this = shift;
  my $t = shift;

  my $failed = 0;
  if(!@_) {
    $this->{m_logger}->error("[ERROR] getPackagesList called with empty arguments!");
    return -1;
  }
  
  foreach my $pack(@_) {
    my $numfail = $this->fetchFileFrom($pack, $this->{m_repos});
    if( $numfail == 0) {
      $this->{m_logger}->warning("[WARNING] Package $pack not found in any repository!");
      if($t =~ m{meta}) {
	push @{$this->{m_fmpacks}}, "$pack";
      }
      else {
	push @{$this->{m_fpacks}}, "$pack";
      }
      $failed++;
    }
  }
  return $failed;
} # getPackagesList



#==========================================
# getMetafileList
#------------------------------------------
# returns:
#   0	= all ok
#   -1	= error in call
#   n>0	= n metafiles failed
#==========================================
sub getMetafileList
{
  my $this = shift;
  if(!$this->{m_basesubdir} or ! -d $this->{m_basesubdir}) {
    $this->{m_logger}->warning("[WARNING] getMetafileList called to early? basesubdir must be set!\n");
    return -1;
  }

  my $failed = 0;
  
  foreach my $mf(keys(%{$this->{m_metafiles}})) {
    my $t = $this->{m_metafiles}->{$mf}->{'target'} || "";
    $this->{m_xml}->getInstSourceFile($mf, "$this->{m_basesubdir}/$t"); # from, to
    my $fname;
    $mf =~ m{.*/([^/]+)$};
    $fname = $1;
    if(not defined $fname) {
      $this->{m_logger}->warning("[WARNING] [getMetafileList] filename $mf doesn't match regexp, skipping\n");
      next;
    }
  }
  return $failed;
} # getPackagesList



#==========================================
# queryRpmHeaders
#------------------------------------------
sub queryRpmHeaders
{
  my $this = shift;

  my $retval = 0;


  foreach my $pack(sort(keys(%{$this->{m_packages}}))) {
    my $tmp = $this->{m_packages}->{$pack}; #optimisation
    #my $arch = $tmp->{'arch'};
    my @archs = grep { $_ !~ m{(addarch|removearch|forcearch|priority|medium)}} keys(%{$tmp});
    #my @archs = $this->checkArchitectureList($pack); # <- des gehoert eh ned an die Stelle! Das muss ganz am Ende gemacht werden, wenn alle Pakete zusammenkopiert sind.

    foreach my $a(@archs) {
      my $uri = "$tmp->{$a}->{'targetpath'}/$tmp->{$a}->{'targetfile'}";
      my $dst = "$this->{'m_basesubdir'}/$tmp->{$a}->{'targetfile'}";
      if(defined($uri) and defined($dst)) {
	# RPMQ query for arch/version/release
	my %flags = KIWIRPMQ::rpmq_many($uri, 'NAME', 'VERSION', 'RELEASE', 'ARCH', 'SOURCE', 'SOURCERPM');
	if(not(%flags
	   and defined $flags{'NAME'}
	   and defined $flags{'VERSION'}
	   and defined $flags{'RELEASE'}
	   and defined $flags{'ARCH'})) {
	  $this->{m_logger}->warning("[WARNING] [queryRpmHeaders] RPM flags query failed for package $pack at $uri!");
	  next;
	}

	my $ad;
	if( !$flags{'SOURCERPM'} or $flags{'SOURCERPM'}->[0] eq 'none') {
	  # we deal with a source rpm...
	  $ad = "src";
	}
	else {
	  # we deal with regular rpm file...
	  $ad = $flags{'ARCH'}->[0];
	}

	my $medium;
	if($tmp && $tmp->{'medium'}) {
	  $medium = $tmp->{'medium'};
	}
	else {
	  $medium = 1;
	}
	my $dstfile = "$this->{'m_united'}/$this->{m_prodinfo}->{'MEDIUM_NAME'}$medium/$ad/$tmp->{$a}->{'targetfile'}";
	$dstfile =~ m{(.*/)(.*?/)(.*?/)(.*)[.]([rs]pm)$};
	if(not(defined($1) and defined($2) and defined($3) and defined($4) and defined($5))) {
	  $this->{m_logger}->error("[ERROR] [queryRpmHeaders] regexp didn't match path $tmp->{'source'}");
	}
	else {
	  $tmp->{$a}->{'newfile'}  = "$pack-$flags{'VERSION'}->[0]-$flags{'RELEASE'}->[0].$ad.$5";
	  $tmp->{$a}->{'newpath'} = "$this->{m_basesubdir}/$ad";
	  $tmp->{$a}->{'arch'}  = $ad;
	  
	  # move and rename:
	  if(!-d $tmp->{$a}->{'newpath'}) {
	    $this->{m_dirlist}->{"$tmp->{$a}->{'newpath'}"} = 1;
	    $this->createDirectoryStructure();
	  }
	  if(!link $uri, "$tmp->{$a}->{'newpath'}/$tmp->{$a}->{'newfile'}") {
	    $this->{m_logger}->warning("[WARNING] [queryRpmHeaders] linking file $tmp->{$a}->{'newpath'}/$tmp->{$a}->{'newfile'} failed");
	  }
	}
      }
      else {
	# this is only the case for unresolved packages!
	$retval++;
	$this->{m_logger}->error("[ERROR] [queryRpmHeaders] package $pack has undefined hash entry");
      }
    }
  }
  return $retval;
}
# /queryRpmHeaders



#==========================================
# queryRpmHeadersPack
#------------------------------------------
sub queryRpmHeadersPack
{
  my $this  = shift;
  my $p	    = shift;
  my $tp    = shift or undef;  # unite path if already known

  my $retval = 0;

  my $tmp = $this->{m_packages}->{$p}; #optimisation
  #my @archs = grep { $_ !~ m{(addarch|removearch|forcearch|priority)}} keys(%{$tmp});
  my @archs = $this->checkArchitectureList($p);

  foreach my $a(@archs) {
    my $uri = "$tmp->{$a}->{'targetpath'}/$tmp->{$a}->{'targetfile'}";
    my $dst = "$this->{'m_basesubdir'}/$tmp->{$a}->{'targetfile'}";
    if(defined($uri) and defined($dst)) {
      # RPMQ query for arch/version/release
      my %flags = KIWIRPMQ::rpmq_many($uri, 'NAME', 'VERSION', 'RELEASE', 'ARCH', 'SOURCE', 'SOURCERPM');
      if(not(%flags
	 and defined $flags{'NAME'}
	 and defined $flags{'VERSION'}
	 and defined $flags{'RELEASE'}
	 and defined $flags{'ARCH'})) {
	$this->{m_logger}->warning("[WARNING] [queryRpmHeaders] RPM flags query failed for package $p at $uri!");
	next;
      }

      my $ad;
      if( !$flags{'SOURCERPM'} or $flags{'SOURCERPM'}->[0] eq 'none') {
	# we deal with a source rpm...
	# yet some more specialities may be necessary here...
	$ad = "src";
      }
      else {
	# we deal with regular rpm file...
	$ad = $flags{'ARCH'}->[0];
      }

      my $dstfile = '';
      if(defined($tp)) {
	$dstfile = "$tp/$ad/$tmp->{$a}->{'targetfile'}";
      }
      else {
	$dstfile = "$this->{m_basesubdir}/$ad/$tmp->{$a}->{'targetfile'}";
      }

      $dstfile =~ m{(.*/)(.*?/)(.*?/)(.*)[.]([rs]pm)$};
      if(not(defined($1) and defined($2) and defined($3) and defined($4) and defined($5))) {
	$this->{m_logger}->error("[ERROR] [queryRpmHeaders] regexp didn't match path $tmp->{'source'}");
      }
      else {
	$tmp->{$a}->{'newfile'}  = "$p-$flags{'VERSION'}->[0]-$flags{'RELEASE'}->[0].$ad.$5";
	$tmp->{$a}->{'newpath'} = "$this->{m_basesubdir}/$ad";
	$tmp->{$a}->{'arch'}  = $ad;
	
	# move and rename:
	if(!-d $tmp->{$a}->{'newpath'}) {
	  if(!mkpath($tmp->{$a}->{'newpath'}, { mode => umask } )) {
	    $this->{m_logger}->warning("[WARNING] [queryRpmHeaders] Couldn't create uniting directory $tmp->{$a}->{'newpath'}");
	  }
	}
	if(!link $uri, "$tmp->{$a}->{'newpath'}/$tmp->{$a}->{'newfile'}") {
	  $this->{m_logger}->warning("[WARNING] [queryRpmHeaders] linking file $tmp->{$a}->{'newpath'}/$tmp->{$a}->{'newfile'} failed");
	}
      }
    }
    else {
      # this is only the case for unresolved packages!
      $retval++;
      $this->{m_logger}->error("[ERROR] [queryRpmHeaders] package $p has undefined hash entry");
    }
  }
  return $retval;
}
# /queryRpmHeadersPack



#==========================================
# collectPackages
#------------------------------------------
# collect all required packages from any repo
# This method defines the central workflow.
# I'll try to keep this very brief and clear
# and put the 'real' work in tiny submethods
# which should be considered private and will
# therefore be called "_something"
#------------------------------------------
# Parameters
# $this - reference to the object for which it is called
#------------------------------------------
sub collectPackages
{
  my $this = shift;

  my $retval = undef;
  my $rfailed = 0;
  my $mfailed = 0;


  ### step 1
  # expand dir lists (setup in constructor for each repo) to filenames
  $this->{m_logger}->info("");
  $this->{m_logger}->info("STEP 1 [collectPackages]");
  $this->{m_logger}->info("expand dir lists for all repositories");
  #foreach my $r(keys(%{$this->{m_repos}})) {
  foreach my $r(@{$this->{m_srclist}}) {
    my $tmp_ref = \%{$this->{m_repos}->{$r}->{'srcdirs'}};
    foreach my $dir(keys(%{$this->{m_repos}->{$r}->{'srcdirs'}})) {
      # directories are scanned during Init()
      # expandFilenames scans the already known directories for matching filenames, in this case: *.rpm, *.spm
      $tmp_ref->{$dir} = [ $this->{m_util}->expandFilename($this->{m_browser}, $this->{m_repos}->{$r}->{'source'}.$dir, '.*[.][rs]pm$') ];
    }
  }

  # dump files for debugging purposes:
  $this->dumpRepoData("$this->{m_basedir}/repolist.txt");


  $this->{m_logger}->info("retrieve package lists for regular packages");
  my $result = $this->getPackagesList("norm", keys(%{$this->{m_packages}}));
  if( $result == -1) {
    $this->{m_logger}->error("getPackagesList for regular packages called with invalid parameter");
  }
  else {
    $this->failedPackagesWarning("[repopackages]", $result, $this->{m_fpacks});
    $rfailed += $result;
  }

  $this->{m_logger}->info("retrieve package lists for metapackages");
  $result += $this->getPackagesList("meta", keys(%{$this->{m_metapackages}}));
  if( $result == -1) {
    $this->{m_logger}->error("getPackagesList for metapackages called with invalid parameter");
  }
  else {
    # continue: check arch list
    $this->failedPackagesWarning("[metapackages]", $result, $this->{m_fmpacks});
    $mfailed += $result;
  }

  ## verify if the architecture requirements are met:
  # TEST code only: later move to fetchFileFrom!
  #foreach my $pack(keys(%{$this->{m_packages}})) {
  #  $this->checkArchitectureList($pack);
  #}

  if(!($mfailed or $rfailed)) {
    $this->{m_logger}->info("[OK] [collectPackages] All packages resolved successfully.\n");
    $retval = 0;
  }
  else {
    $retval++;
  }


  ### step 2:
  $this->{m_logger}->info("");
  $this->{m_logger}->info("STEP 2 [collectPackages]");
  $this->{m_logger}->info("Query RPM archive headers for undecided archives");

  # query all package headers for "undecided/unknown" packages and decide them!
  my $headererrors = $this->queryRpmHeaders();
  if($headererrors > 0) {
    $this->{m_logger}->error("[ERROR] [collectPackages] $headererrors RPM headers have errors (don't hold required flags)");
    $retval++;
  }


  ### step 3: NOW I know where you live...
  $this->{m_logger}->info("");
  $this->{m_logger}->info("STEP 3 [collectPackages]");
  $this->{m_logger}->info("Handle scripts for metafiles and metapackages");
  # unpack metapackages and download metafiles to the {m_united} path
  # (or relative path from there if specified) <- according to rnc file
  # this must not be empty in any case

  # download metafiles to new basedir:
  $this->getMetafileList();

  $this->{m_scriptbase} = "$this->{m_united}/scripts";
  if(!mkpath($this->{m_scriptbase}, { mode => umask } )) {
    $this->{m_logger}->error("[ERROR] [collectPackages] Cannot create script directory!");
    die;  # TODO clean exit somehow
  }

  my @metafiles = keys(%{$this->{m_metafiles}});
  if(!$this->executeMetafileScripts(@metafiles)) {
    $this->{m_logger}->error("[ERROR] [collectPackages] executing metafile scripts failed!");
    $retval++;
  }

  # create some dirs needed for metapackage handling:
  #my @mfsubdirs;
  #for(1..5) {
  #  push @mfsubdirs, "$this->{m_united}/CD$_";
  #  mkdir("$this->{m_united}/CD$_", 0755);
  #}
  #@{$this->{m_metasubdirs}} = @mfsubdirs;


  my @packagelist = sort(keys(%{$this->{m_metapackages}}));
  if(!$this->unpackMetapackages(@packagelist)) {
    $this->{m_logger}->error("[ERROR] [collectPackages] executing scripts failed!");
    $retval++;
  }


  ### step 4: run scripts for other (non-meta) packages
  # TODO (copy/paste?)
  

  ### step 5: create metadata
  $this->createMetadata();

  return $retval;
}
# /collectPackages



#==========================================
# executeMetapackageScripts
#------------------------------------------
# metafiles and metapackages may have an attribute called 'script'
# which shall be executed after the packages are gathered.
# TODO: find a way to secure this
#   ISSUES:
# I'd very much like to setup a chroot environment for that, but then
# all binaries that will be used need to be copied/linked beneath the
# new root.
# - metaPACKAGES _could_ define dependencies through RPM's
#   REQUIRES mecahnism. Lars is working on that so this will come soon.
# - different for metaFILES because they are loose and don't have any
#   install mechanism yet. We think about this.
#==========================================
sub unpackMetapackages
{
  my $this = shift;

  # the second (first explicit) parameter is a list of packages
  my @packlist = @_;

  foreach my $metapack(@packlist) {
    my %tmp = %{$this->{m_metapackages}->{$metapack}};

    ## regular handling: unpack, put everything from CD1..CD<n> to cdroot {m_basedir}
    # ...
    my $tmp = "$this->{m_united}/temp";
    if(-d $tmp) {
      qx(rm -rf $tmp);
      #rmdir -p $tmp; #no force available?
    }
    if(!mkpath("$tmp", { mode => umask } )) {
      $this->{m_logger}->error("[ERROR] can't create dir $tmp\n");
      die;
    }
    
    my %dirs = $this->getSrcList($metapack);
    if(!%dirs) {
      $this->{m_logger}->error("[ERROR] [unpackMetapackages] dirs not defined!\n");
      next;
      #return undef; # rock hard exit here, can't proceed without the proper input
    }
    my $dir = (sort(keys(%dirs)))[0];	# experimental! TODO

    $this->{m_util}->unpac_package($this->{m_packages}->{$metapack}->{$dir}->{'source'}, "$tmp");
    ## all metapackages contain at least a CD1 dir and _may_ contain another /usr/share/<name> dir
    qx(cp -r $tmp/CD1/* @{$this->{m_metasubdirs}}[0]);
    if(-d "$tmp/usr/share") {
      qx(cp -r $tmp/usr/share/ $this->{m_united});
    }
    ## copy content of CD2 ... CD<i> subdirs if exists:
    for(2..5) {
      if(-d "$tmp/CD$_") {
	qx(cp -r $tmp/CD$_ @{$this->{m_metasubdirs}});
      }
      ## add handling for "DVD<i>" subdirs if necessary FIXME
    }

    ## THEMING
    $this->{m_logger}->info("[INFO] Handling theming for package $metapack\n");
    $this->{m_logger}->info("\ttarget theme $this->{m_prodinfo}->{PRODUCT_THEME}\n");
    my $thema = $this->{m_prodinfo}->{'PRODUCT_THEME'};
    if(-d "$tmp/SuSE") { # and -d "$tmp/SuSE/$thema") {
      if(not opendir(TD, "$tmp/SuSE")) {
	$this->{m_logger}->warning("[WARNING] [unpackMetapackages] Can't open theme directory for reading!\nSkipping themes for package $metapack\n");
	next;
      }
      my @themes = readdir(TD);
      closedir(TD);
      my $found=0;
      foreach my $d(@themes) {
	if($d =~ m{$thema}i) {
	  $this->{m_logger}->info("Using thema $d\n");
	  $found=1;
	  last;
	}
      }
      if($found==0) {
	foreach my $d(@themes) {
	  if($d =~ m{Linux|SLES}i) {
	    $this->{m_logger}->info("Using fallback theme $d instead of $thema\n");
	    $thema = $d;
	    last;
	  }
	}
      }
      ## $thema is now the thema to use:
      for my $i(1..3) {
	if(-d "$tmp/SuSE/$thema/CD$i") {
	  qx(cp -a $tmp/SuSE/$thema/CD$i/* @{$this->{m_metasubdirs}}[$i-1]);
	}
      }
    }

    ## handling optional special scripts if given (``anchor of the last choice'')
    if($tmp{'script'}) {
      my $scriptfile;
      $tmp{'script'} =~ m{.*/([^/]+)$};
      if(defined($1)) {
	$scriptfile = $1;
      }
      else {
	$this->{m_logger}->warning("[WARNING] [executeScripts] malformed script name: $tmp{'script'}");
	next;
      }

      print "Downloading script $tmp{'script'} to $this->{m_scriptbase}:";
      $this->{m_xml}->getInstSourceFile($tmp{'script'}, "$this->{m_scriptbase}/$scriptfile");

      # TODO I don't like this. Not at all. use chroot in next version!
      qx(chmod u+x "$this->{m_scriptbase}/$scriptfile");
      $this->{m_logger}->info("[INFO] [executeScripts] Execute script $this->{m_scriptbase}/$scriptfile:\n");
      if(-f "$this->{m_scriptbase}/$scriptfile" and -x "$this->{m_scriptbase}/$scriptfile") {
	my $status = qx($this->{m_scriptbase}/$scriptfile);
	my $retcode = $? >> 8;
	print "STATUS:\n$status\n";
	print "RETURNED:\n$retcode\n";
      }
      else {
	$this->{m_logger}->warning("[WARNING] [executeScripts] script $this->{m_scriptbase}/$scriptfile for metapackage $metapack could not be executed successfully!\n");
      }
    }
    else {
      $this->{m_logger}->info("No script defined for metapackage $metapack\n");
    }
  }
}
# /executeScripts



#==========================================
# executeMetafileScripts
#------------------------------------------
sub executeMetafileScripts
{
  my $this = shift;

  # the second (first explicit) parameter is a list of either packages or files
  # for which scripts shall be executed.
  my @filelist = @_;

  foreach my $metafile(@filelist) {
    my %tmp = %{$this->{m_metafiles}->{$metafile}};
    if($tmp{'script'}) {
      my $scriptfile;
      ## TODO doesn't work for local files! (no bla/script.x) (abs paths required?)
      $tmp{'script'} =~ m{.*/([^/]+)$};
      if(defined($1)) {
	$scriptfile = $1;
      }
      else {
	$this->{m_logger}->warning("[WARNING] [executeScripts] malformed script name: $tmp{'script'}\n");
	next;
      }

      print "Downloading script $tmp{'script'} to $this->{m_scriptbase}:";
      $this->{m_xml}->getInstSourceFile($tmp{'script'}, "$this->{m_scriptbase}/$scriptfile");

      # TODO I don't like this. Not at all. use chroot in next version!
      qx(chmod u+x "$this->{m_scriptbase}/$scriptfile");
      $this->{m_logger}->info("[INFO] [executeScripts] Execute script $this->{m_scriptbase}/$scriptfile:");
      if(-f "$this->{m_scriptbase}/$scriptfile" and -x "$this->{m_scriptbase}/$scriptfile") {
	my $status = qx($this->{m_scriptbase}/$scriptfile);
	my $retcode = $? >> 8;
	print "STATUS:\n$status\n";
	print "RETURNED:\n$retcode\n";
      }
      else {
	$this->{m_logger}->warning("[WARNING] [executeScripts] script $this->{m_scriptbase}/$scriptfile for metafile $metafile could not be executed successfully!\n");
      }
    }
    else {
      $this->{m_logger}->info("No script defined for metafile $metafile\n");
      
    }
  }
}
# /executeScripts



#==========================================
# bestBet
#------------------------------------------
# creates a list with possible download locations
# for package $pack indexed by the priority
#==========================================
sub bestBet
{
  my $this = shift;
  my $pack = shift;

  my %result;
  my $pack_safe = $pack;
  $pack_safe =~ s{[+]}{\[+\]}g;	# quote nested quantifiers (e.g. "dvd+rw-tools" is dangerous)

  $this->{m_logger}->info("current package: $pack ");

  my $found_in_repo;
  my $undecided = 0;
  my $tmp;
  #my @fallbackarchs;

  REPO:foreach my $r(keys(%{$this->{m_repos}})) {
    DIR:foreach my $d(keys(%{$this->{m_repos}->{$r}->{'srcdirs'}})) {
      next DIR  if(! $this->{m_repos}->{$r}->{'srcdirs'}->{$d}->[0]);
      #next DIR if($d ne "/" and $d !~ m{$fa});

      my $subdirname = undef;
      my $archinfo;
      URI:foreach my $uri(@{$this->{m_repos}->{$r}->{'srcdirs'}->{$d}}) {
	#$this->{m_logger}->info("current uri: $uri ");
	if($d eq "/") {
	  if($uri =~ m{^.*/$pack_safe-[\d.]+.*[.]([^.]+)[.][rs]pm$}) {
	    # case 1: dir is "/", vers.nr. in name, arch is $1:
	    $subdirname = "$1/";
	    # don't use $fa here because the pack is found in the first subdir in this case
	    $archinfo = $1;
	  }
	  elsif($uri =~ m{^.*/$pack_safe[.][rs]pm$}) {
	    # case 2: dir is "/", no version info
	    $subdirname = "undecided/unknown/";
	    $archinfo = "unknown";
	    $undecided++;
	  }
	  else {
	    next URI;
	  }
	  $found_in_repo++;
	}
	elsif($d =~ m{.*/([^/]+)/$}) {
	  if($uri =~ m{^.*/$pack_safe-[\d.]+.*[.]([^.]+)[.][rs]pm$}) {
	    # case 3: dir is like "/suse/x86_64/", vers.nr. in name, arch is $1:
	    $subdirname = "$1/";
	    $archinfo = $1;
	  }
	  elsif($uri =~ m{^.*/$pack_safe[.][rs]pm$}) {
	    # case 4: dir is like "/suse/x86_64/", no version info
	    $subdirname = "undecided/unknown";
	    $archinfo = "unknown";
	    $undecided++;
	  }
	  else {
	    # error
	    #$this->{m_logger}->info("[ERROR] $pack not available for required architecture $arc\n");
	    next URI;
	  }
	  $found_in_repo++;
	}
	else {
	  # Error
	  $this->{m_logger}->info("[WARINIG] [bestBet] URI doesn't match directory convention\n");
	  next URI;
	}

	if(!defined($subdirname)) {
	  $this->{m_kiwi}->error("Subdirname is empty!");
	  next DIR;
	}
	$this->{m_logger}->info("[OK] [bestBet] $pack available in repository $r (Priority $this->{m_repos}->{$r}->{'priority'}) at URI $uri\n");

	# subdirname, archinfo are set;
	if(defined $result{$r}) {
	  $tmp = $result{$r};
	}
	else {
	  $tmp = {}; # reference to new anonymous hash
	  $result{$r} = $tmp;
	}

	$tmp->{$d} = {};
	$tmp->{$d}->{'arch'} = $archinfo;
	$tmp->{$d}->{'subdir'} = $subdirname;
	$tmp->{$d}->{'uri'} = $uri;

	# pull the BIG next lever:
	next DIR; # look in other dirs in same repo please (a repo might contain the same package for multiple architectures
      }
    }
  }	# $r (repository, sorted by priority)
      #if($found_in_repo > 0) {

  return %result;
}
# /bestBet



#==========================================
# fetchFileFrom
#------------------------------------------
# Downloads or copies a file from one of the
# given repositories or issues a warning if
# the package isn't found anywhere
#------------------------------------------
# Parameters
# ==========
# $this:
#   reference to the object for which it is called
# $pack:
#   package to acquire
# $repref:
#   reference to the hash of available repositories
#------------------------------------------
# Returns the number of resolved files, or 0 for bad list
#------------------------------------------
sub fetchFileFrom
{
  my $this   = shift;
  my $pack   = shift;
  my $repref = shift;
  my $force  = shift; # may be omitted

  my $retval = 0;

  my %list = $this->bestBet($pack);
  return $retval if(! %list);

  # step1: download all and query headers!
  # sort by prio??
  #REPO:foreach my $repo(keys(%list)) {
  REPO:foreach my $repo(sort {$this->{m_repos}->{$a}->{priority} < $this->{m_repos}->{$b}->{priority}} keys(%list)) {
    my $r_tmp = $list{$repo};
    DIR:foreach my $dir(keys(%{$r_tmp})) {
      my $r_tmp2 = $r_tmp->{$dir};
      my $uri = $r_tmp2->{'uri'};

      my $fullpath = "$this->{m_repos}->{$repo}->{'basedir'}/$r_tmp2->{'subdir'}";
      $this->{m_dirlist}->{"$fullpath"} = 1;
      $this->createDirectoryStructure();
      #if(! -d $fullpath) {
      #  if(!mkpath($fullpath, { mode => umask })) {
      #    $this->{m_logger}->error("[ERROR] [fetchFileFrom] cannot create subdirectory $fullpath\n");
      #    die "Cannot create subdirectories, something's broken!";
      #  }
      #}

      $this->{m_logger}->info("[INFO] [fetchFileFrom] downloading $pack from $r_tmp2->{'uri'} to dir $fullpath");
      $r_tmp2->{'uri'} =~ m{.*/(.*)$};
      my $file = $1;
      $this->{m_xml}->getInstSourceFile($r_tmp2->{'uri'}, $fullpath);
      my %flags = KIWIRPMQ::rpmq_many("$fullpath/$file", 'NAME', 'VERSION', 'RELEASE', 'ARCH', 'SOURCE', 'SOURCERPM');

      if(! %flags) {
	$this->{m_logger}->warning("[WARNING] [fetchFileFrom] Package $pack seems to have an invalid header!");
      }
      else {
	my $arch = $flags{'ARCH'}->[0];
	#=================================
	# SOURCE:
	#   -> See rpm --querytags and http://www.rpm.org/max-rpm/ch-queryformat-tags.html
	#   SOURCE contains (none) for regular rpms and the name of the tarball file for source rpms
	#   SOURCERPM contains the name of the resp. source rpm or (none) for source rpms themselves.
	#---------------------------------
	#my $ext = "$tmppath/$flags{'NAME'}->[0]-$flags{'VERSION'}->[0]-$flags{'RELEASE'}->[0]";
	my $ext;
	if( !$flags{'SOURCERPM'} or $flags{'SOURCERPM'}->[0] eq 'none') {
	  # we deal with a source rpm...
	  $ext .= "$arch.src.rpm";
	  $r_tmp2->{'subdir'} = "src";
	}
	else {
	  # we deal with regular rpm file...
	  $ext .= "$arch.rpm";
	  $r_tmp2->{'subdir'} = $arch;
	}

	$r_tmp2->{'arch'} = $arch;
	my $tmppath = "$this->{m_repos}->{$repo}->{'basedir'}/temp/$r_tmp2->{'subdir'}";

	if(! -d $tmppath) {
	  $this->{m_dirlist}->{"$tmppath"} = 1;
	  $this->createDirectoryStructure();
	  #if(!mkpath($tmppath, { mode => umask } )) {
	  #  $this->{m_logger}->error("[ERROR] [fetchFileFrom] cannot create subdirectory $tmppath\n");
	  #  # TODO clean exit (code 3); continuing doesn't make sense
	  #  die "Cannot create subdirectories, something's broken!";
	  #}
	}

	my $newname = "$tmppath/$flags{'NAME'}->[0]-$flags{'VERSION'}->[0]-$flags{'RELEASE'}->[0].$ext";
	rename "$fullpath/$file", $newname;
	# now everything is in /temp with correct arch/src/stuff info.
	# We can now sort out the required architectures once and for all.
	my $store;
	my $subdir = $r_tmp2->{'subdir'};
	if($this->{m_packages}->{$pack}) {
	  $store = $this->{m_packages}->{$pack};
	}
	else {
	  $store = {};
	  $this->{m_packages}->{$pack} = $store;
	}
	if(!$store->{$subdir}) {
	  $store->{$subdir} = {};
	}

	$store->{$subdir}->{'arch'} = $arch;
	$store->{$subdir}->{'source'} = $r_tmp2->{'uri'};
	$store->{$subdir}->{'targetpath'} = $tmppath;
	$newname =~ m{.*/([^/]+)};
	$store->{$subdir}->{'targetfile'} = $1;
	$retval++;
      }
    } # foreach DIR
  } # foreach REPO
  return $retval;
}
# /fetchFileFrom



#==========================================
# dumpRepoData
#------------------------------------------
sub dumpRepoData
{
  # dumps data collected in $this-> ... for debugging purpose.
  # receives a file name as parameter.
  # If file can't be openend, a warning is issued through $this->{m_kiwi}
  # and nothing else happens.
  # Successful completion provides a list of content in the file.
  my $this    = shift;
  my $target  = shift;

  if(!open(DUMP, ">", $target)) {
    $this->{m_kiwi}->warning("[WARNING] [dumpRepoData] Dumping data to file $target failed: file could not be created!");
    $this->{m_kiwi}->failed();
  }

  print DUMP "Dumped data from KIWICollect object\n\n";

  print DUMP "\n\nKNOWN REPOSITORIES:\n";
  foreach my $repo(keys(%{$this->{m_repos}})) {
    print DUMP "\nNAME:\t\"$repo\"\t[HASHREF]\n";
    print DUMP "\tBASEDIR:\t\"$this->{m_repos}->{$repo}->{'basedir'}\"\n";
    print DUMP "\tPRIORITY:\t\"$this->{m_repos}->{$repo}->{'priority'}\"\n";
    print DUMP "\tSOURCEDIR:\t\"$this->{m_repos}->{$repo}->{'source'}\"\n";
    print DUMP "\tSUBDIRECTORIES:\n";
    foreach my $srcdir(keys(%{$this->{m_repos}->{$repo}->{'srcdirs'}})) {
      print DUMP "\t\"$srcdir\"\t[URI LIST]\n";
      foreach my $file(@{$this->{m_repos}->{$repo}->{'srcdirs'}->{$srcdir}}) {
	print DUMP "\t\t\"$file\"\n";
      }
    }
  }

  close(DUMP);
  return;
}
# /dumpRepoData



#==========================================
# getArchList
#------------------------------------------
sub getArchList
{
  my $this = shift;
  
  my @erg = ();
  #my @archs = @{$this->{m_archlist}};

  foreach(@{$this->{m_archlist}}) {
    if(m{i\d+}) {
      push @erg, $this->getArchListByName('intel', $_);
    }
    elsif(m{ia.+}) {
      push @erg, $this->getArchListByName('ia', $_);
    }
    elsif(m{ppc}) {
      push @erg, $this->getArchListByName('ppc', $_);
    }
    elsif(m{ppc64}) {
      push @erg, $this->getArchListByName('ppc64', $_);
    }
    elsif(m{hppa}) {
      push @erg, $this->getArchListByName('hp', $_);
    }
    elsif(m{x\d+}) {
      push @erg, $this->getArchListByName('amd', $_);
    }
    elsif(m{s\d+.*}) {
      push @erg, $this->getArchListByName('s390', $_);
    }
  }
  return KIWIUtil::unify(@erg);
}
# /getArchList



#
sub getArchListByName
{
  my $this = shift;
  my $arch = shift;# or die("No arch given!");
  # missing pars warning hook:
  if(not defined($arch)) {
    $this->{m_logger}->warning("[WARNING] [getArchByName] undefined parameter \$arch");
    return undef; # no harm, but also no result
  }

  my @orig;
  if($arch =~ m{i\d+}) {
    @orig = @{$this->{m_fpath}->{'intel'}};
  }
  elsif($arch =~ m{ia.+}) {
    @orig = @{$this->{m_fpath}->{'ia'}};
  }
  elsif($arch =~ m{ppc}) {
   @orig = @{$this->{m_fpath}->{'ppc'}};
  }
  elsif($arch =~ m{ppc64}) {
   @orig = @{$this->{m_fpath}->{'ppc64'}};
  }
  elsif($arch =~ m{hppa}) {
   @orig = @{$this->{m_fpath}->{'hp'}};
  }
  elsif($arch =~ m{x\d+}) {
   @orig = @{$this->{m_fpath}->{'amd'}};
  }
  elsif($arch =~ m{s\d+.*}) {
   @orig = @{$this->{m_fpath}->{'s390'}};
  }

  my $index = 0;
  for($index=0; $index<$#orig; $index++) {
    if($orig[$index] eq $arch) {
      last;
    }
  }
  return @orig[$index .. $#orig];
}
# /getArchListByName



#==========================================
# dumpPackageList
#------------------------------------------
sub dumpPackageList
{
  # dumps data collected in $this->{m_packages} for debugging purpose.
  # receives a file name as parameter.
  # If file can't be openend, a warning is issued through $this->{m_kiwi}
  # and nothing else happens.
  # Successful completion provides a list of content in the file.
  my $this    = shift;
  my $target  = shift;

  if(!open(DUMP, ">", $target)) {
    $this->{m_kiwi}->warning("[WARNING] [dumpPackageList] Dumping data to file $target failed: file could not be created!");
    $this->{m_kiwi}->failed();
  }

  print DUMP "Dumped data from KIWICollect object\n\n";

  print DUMP "LIST OF REQUIRED PACKAGES:\n\n";
  foreach my $pack(keys(%{$this->{m_packages}})) {
    print DUMP "$pack";
    if(defined($this->{m_packages}->{$pack}->{'priority'})) {
      print DUMP "\t (prio=$this->{m_packages}->{$pack}->{'priority'})\n";
    }
    else {
      print DUMP "\n";
    }
  }
  close(DUMP);
  return;
}
# /dumpData



#==========================================
# checkArchitectureList
#------------------------------------------
# As all available RPMs have been downloaded successfully,
# the big required architecture list must be checked and 
# the user must be flooded with info/warnings/errors.
# It is necessary to download _all_ RPM files first to sort
# out cases where the filename provides no usable information
#------------------------------------------
# 
sub checkArchitectureList
{
  my $this = shift;
  return undef if !$this;

  my $pack = shift;
  return undef if !$pack;
  
  my @ret = ();
  # the required architectures as specified in config.xml:
  # mapped to 0 means "removed"	(removearch)
  #	      1 means "original from config.xml"
  #	      2 means "added" (addarch)
  #	      3 means "force" (forcearch)
  # for ADDED (=2) archs no fallback expansion is done!
  my %requiredarch = map { $_ => 1 } @{$this->{m_archlist}};

  my @addarchs = ();
  my @remarchs = ();

  if(defined($this->{m_packages}->{$pack}) and $this->{m_packages}->{$pack}->{'forcearch'}) {
    $requiredarch{$this->{m_packages}->{$pack}->{'forcearch'}} = 3;
  }
  else {
    # step 1 - sort out the one and only definite architecture list:
    if(defined($this->{m_packages}->{$pack}) and $this->{m_packages}->{$pack}->{'addarch'}) {
      @addarchs = split(',', $this->{m_packages}->{$pack}->{'addarch'});
      if(@addarchs) {
	$this->{m_logger}->info("Additional architecture(s) for package $pack: ");
	foreach(@addarchs) {
	  $this->{m_logger}->info("\t$_");
	  $requiredarch{$_} = 2;
	}
      }
    }

    if(defined($this->{m_packages}->{$pack}) and $this->{m_packages}->{$pack}->{'removearch'}) {
      @remarchs = split(',', $this->{m_packages}->{$pack}->{'removearch'});
      if(@remarchs) {
	foreach(@remarchs) {
	  $requiredarch{$_} = 0;
	}
      }
    }
  }

  $this->{m_logger}->info("[INFO] Architectures for package $pack:");
  foreach my $a(keys(%requiredarch)) {
    if($requiredarch{$a} == 3) {
      $this->{m_logger}->info("\tarch $a forced");
      push @ret, $a;
      last;
    }
    elsif($requiredarch{$a} == 1) {
      $this->{m_logger}->info("\tarch $a as per global list");
      push @ret, $this->getArchListByName($a);
    }
    elsif($requiredarch{$a} == 2) {
      $this->{m_logger}->info("\tarch $a added explicitely");
      push @ret, $a;
    }
    elsif($requiredarch{$a} == 0) {
      $this->{m_logger}->info("\tarch $a removed.");
    }
  }
  return @ret;
}



sub failedPackagesWarning
{
  my $this = shift;
  my $call = shift;
  my $numf = shift;
  my $flist = shift;

  goto all_ok if($numf == 0);

  $this->{m_logger}->info("[ERROR] $call: $numf packages not found");
  foreach my $pack(@{$flist}) {
    $this->{m_logger}->error("[ERROR] [collectPackages]\t$pack\n");
  }

  all_ok:
  return;
}




#==========================================
# hasArch
#------------------------------------------
# query a single package for its available
# architectures
#------------------------------------------
# params:
#   package name
# returns:
#   list of available architectures
#------------------------------------------
sub hasArch
{
  my $this = shift;
  my $p = shift;

  my @r = ();
  my $pinfo = $this->{m_packages}->{$p};
  if(!$pinfo) {
    $pinfo = $this->{m_metapackages}->{$p};
    if(!$pinfo) {
      $this->{m_logger}->warning("[WARNING] [hasArch] package $p not found in any package list");
      return undef;
    }
  }

  # figure out the reqired architectures:
  if(!@{$pinfo}) { # if the ref is an empty list
    @r = $this->{m_archlist};
  }
  else {
    
  }

  return @r;
}



#==========================================
# createMetadata
#------------------------------------------
# 
#------------------------------------------
# params:
#------------------------------------------
sub createMetadata
{
  my $this = shift;

  my $path = $this->{m_basesubdir};
  $this->{m_logger}->info("Calling create_package_descr for directory $path:");
  if(! (-f "/usr/bin/create_package_descr" or -x "/usr/bin/create_package_descr")) {
    $this->{m_logger}->warning("[WARNING] [createMetadata] excutable `/usr/bin/create_package_descr` not found. Maybe package `inst-source-utils` is not installed?");
    return;
  }

  my $data = qx(cd $path && /usr/bin/create_package_descr -p /mounts/work/cd/data/pdb/stable -d $path -P -Z -C -K -M 3 -l german -l english -l french -l czech -l spanish -l hungarian);
  my $status = $? >> 8;

}



sub getSrcList
{
  my $this = shift;
  my $p = shift;

  return undef if(!$p);

  my %src;
  foreach my $a(keys(%{$this->{m_packages}->{$p}})) {
    if(!$this->{m_packages}->{$p}->{$a}->{'source'}) {
      # pack without source is bäh!
      goto error;
    }
    $src{$a} = $this->{m_packages}->{$p}->{$a}->{'source'}
  }
  return %src;

  error:
  $this->{m_logger}->warning("[WARNING] [getSrcList] source not defined, method called before downloads complete!\n");
  return undef;
}



#==========================================
# createDirecotryStructure
#------------------------------------------
# Creates and updates the directories that are created during
# installation source creation.
#------------------------------------------
# Hash values of %{$this->{m_dirlist}}:
# 0 = directory exists
# 1 = directory must be created
# 2 = an error occured at creation
#------------------------------------------
sub createDirectoryStructure
{
  my $this = shift;
  my %dirs = %{$this->{m_dirlist}};
  #if(!%dirs) {
  #  $this->{m_logger}->info("[INFO] createDirectoryStructure: nothing to do at the moment.");
  #  return 0;
  #}
  my $errors = 0;

  #for my $i(0..scalar(@dirs)-1) {
  foreach my $d(keys(%dirs)) {
    if(-d $d) {
      $this->{m_logger}->info("[INFO] directory $d already exists, skipping");
      $dirs{$d} = 0;
    }
    elsif(!mkpath($d, 0755)) {
      $this->{m_logger}->error("[ERROR] createDirectoryStructure: can't create directory $d!");
      $dirs{$d} = 2;
      $errors++;
    }
    else {
      $this->{m_logger}->info("[INFO] created directory $d");
    }
    $dirs{$d} = 0;
  }

  #@{$this->{m_dirlist}} = grep { defined($_) } @dirs;

  if($errors) {
    $this->{m_logger}->error("[ERROR] createDirectoryStructure failed. Abort recommended.");
    $this->{m_kiwi}->kiwiExit(3);
    return undef;
  }
  else {
    return 0;
  }
}



sub getDirStatus
{
  my $this = shift;
}



#==========================================
# getMediaNumbers
#------------------------------------------
# Returns a list containing all the media involved in a
# product. Each number is only reported once.
# The list may contain leaks (1,2,5,6 is perfectly ok)
#------------------------------------------
sub getMediaNumbers
{
  my $this = shift;
  return undef if not defined $this;
  
  my @media;
  foreach my $p(values(%{$this->{m_packages}}), values(%{$this->{m_metapackages}})) {
    if(defined($p->{'medium'}) and $p->{'medium'} != 0) {
      push @media, $p->{medium};
    }
  }
  return sort(KIWIUtil::unify(@media));
}



1;

