#!/usr/bin/env bash

# _______________________________________________________________________
# usage and parsing

usage() {
    echo "${0##*/} [-t] [-h] [-l] [-z] [-o <output_dir>] <fit inputs>" >&2
}

OUTDIR=fit_figs_and_tables
FIT_INPUTS=fit_inputs

# stuff for robustness (quit on nonzero exit, treat unset access as error)
set -eu

# monojet limits
MONOJET_LIMITS=$FIT_INPUTS/mono-observed-exclusion.txt
# these get combined with our limits
SC_CLSFILE=$FIT_INPUTS/stop-to-charm-cls.yml
# need this to get the cross sections
DATASET_META=$FIT_INPUTS/dataset-meta.yml
# the fit inputs data files
INPUT=$FIT_INPUTS/fit-inputs.yml
TTBAR_INPUT=$FIT_INPUTS/ttbar-rw-fit-inputs.yml
# veto some points due to bug in production
VETO_POINTS="200-125 100-1 150-50 200-1 200-75 250-150 400-300 450-350"
NTOYS=0 			# by default run asymptotic upper limits

doc() {
    usage
    cat <<EOF

Wrapper to run fit limits.

Options:
 -o <out_dir>  set output dir, default $OUTDIR
 -l            also run upper limits (slow)
 -t            run test
 -h, --help    print help
 -z            tar and zip when finished
 --toys        run model independent upper limits with toys (recommend 3000)
EOF
}

function checkarg() {
    if [[ ! $2 ]] ; then
	echo "argument to $1 is missing" >&2
	exit 1
    fi
}

DO_UL=''
ZIP=''
EE=''
while (( $# ))
do
    case $1 in
	--help) doc; exit 1;;
	-h) doc; exit 1;;
	-o) checkarg $@; shift; OUTDIR=$1; shift;;
	-t) EE=-h; shift;;
	-z) ZIP=1; shift;;
	-l) DO_UL=1; shift;;
	--toys) DO_UL=1; checkarg $@; shift; NTOYS=$1; shift;;
	*)
	    if [[ -n $INPUT ]]
		then
		usage
		echo 'too many inputs' >&2
		exit 2
	    else
		INPUT=$1
	    fi
	    shift;;
    esac
done

if [[ -z $INPUT ]]
then
    usage
    echo need file 1>&2
    exit 1
fi

# __________________________________________________________________________
# temp dir for intermediate stuff
TMP_DIR=$(mktemp -d)
function cleanup() {
    echo cleaning up
    rm -rf $TMP_DIR
}
trap cleanup EXIT

# ____________________________________________________________________________
# common utility functions (mostly checking for files)

function check_for_files() {
    if [[ ! -d $1 ]]
    then
	echo can\'t find $1 >&2
	return 2
    fi
    local config=$1/configuration.yml
    if [[ ! -f $config ]]
    then
	echo cant find $config >&2
	return 2
    fi
    return 0
}

function matches_in() {
    # takes a directory, followed by a pattern
    if [[ ! -d $1 ]]
	then
	return 1
    fi
    local NWS=$(find $1 -type f -name $2 | wc -w)
    if (( $NWS > 0 ))
	then
	return 0
    fi
    return 1
}

function check() {
    if ! eval $@ ; then exit 1 ; fi
}

# __________________________________________________________________________
# define the main functions used

function makelim() {
    # first arg: yaml fit input file
    # second arg: subdir of OUTDIR where outputs go
    # thrid arg: cls file to add
    # forth arg: additional stuff to pass to susy-fit-workspace
    local ADD_ARGS=''
    if (( $# >= 4 )) ; then ADD_ARGS=${@:4}; fi
    if ! check_for_files $2 ; then return $?; fi
    local WSDIR=$2/workspaces
    if ! matches_in $WSDIR '*nominal*'
	then
	echo making limits for $2
	local fitargs="-o $WSDIR -c $2/configuration.yml $ADD_ARGS $EE"
	susy-fit-workspace.py $1 $fitargs
    fi
    mkdir -p $OUTDIR/$2
    local CLSFILE=$OUTDIR/$2/cls.yml
    local CLSADD=""
    if (( $# >= 3 )) ; then CLSADD=$3 ; fi
    if [[ ! -f $CLSFILE ]]
	then
	local CLSTMP=$TMP_DIR/cls.yml.tmp
	susy-fit-runfit.py $WSDIR -o $CLSTMP $EE
	if [[ -n $CLSADD && ! -f $CLSADD ]] ; then
	    echo $CLSADD not found! >&2
	    return 1
	fi
	cat $CLSADD $CLSTMP > $CLSFILE
    fi
    echo done limits for $2
}
function drawlim() {
    # first arg: dir with cls
    # remaining args: regions to include (none means all)
    local CLSFILE=$OUTDIR/$1/cls.yml
    local BASEFLAGS='--external' # make external-publication plots
    local ADD=$BASEFLAGS
    if (( $# > 1 )); then
	ADD="-r ${@:2} $BASEFLAGS"
    fi
    if [[ ! -f $CLSFILE ]]; then
	echo no $CLSFILE >&2
	return 1
    fi
    local OVL=$OUTDIR/$1/exclusion_overlay.pdf
    local BST=$OUTDIR/$1/exclusion_best.pdf
    local PTY=$OUTDIR/$1/exclusion_pretty.pdf
    if [[ ! -f $OVL ]] ; then
	echo drawing $OVL
	susy-fit-draw-exclusion.py $CLSFILE -o $OVL $ADD
    fi
    if [[ ! -f $BST ]] ; then
	echo drawing $BST
	susy-fit-draw-exclusion.py $CLSFILE --best-regions -o $BST $ADD
    fi
    if [[ ! -f $PTY ]] ; then
	echo drawing $PTY
	susy-fit-draw-exclusion.py $CLSFILE --mono $MONOJET_LIMITS -o $PTY $ADD
    fi
}
function drawlimsubset() {
    # first arg: dir with cls
    # second arg: out file name (put in dir with cls)
    # all remaining: regions to draw
    local CLSFILE=$OUTDIR/$1/cls.yml
    if [[ ! -f $CLSFILE ]] ; then
	echo no file ${CLSFILE}! >&2
	return 1
    fi
    local CONFIGS="-r ${@:3}"
    local OUTNAME=$OUTDIR/$1/$2
    if [[ ! -f $OUTNAME ]] ; then
	echo drawing $2 from $CLSFILE
	susy-fit-draw-exclusion.py $CLSFILE -o $OUTNAME $CONFIGS
    fi
}

function draw-cls-between () {
    local CLS1=$OUTDIR/$1/cls.yml
    local CLS2=$OUTDIR/$2/cls.yml
    local ext=$3
    local OUT=$OUTDIR/$4
    local EXTRA=${@:5}
    mkdir -p $OUT
    local OUTFILE=$OUT/cls_combined.yml
    if [[ ! -f $OUTFILE ]] ; then
	echo building $OUTFILE
	if [[ -z $ext ]] ; then
	    cat $CLS1 $CLS2 > $OUTFILE
	else
	    susy-fit-cls-rename.py $CLS2 $ext | cat $CLS1 - > $OUTFILE
	fi
    fi
    local OUTPLOT=$OUT/compared_exclusion.pdf
    if [[ ! -f $OUTPLOT ]] ; then
	echo drawing $OUTPLOT
	susy-fit-draw-exclusion.py $OUTFILE -o $OUTPLOT $EXTRA
    fi
}

function makews_updown() {
    # first arg: yaml fit input file
    # second arg: subdir of OUTDIR where outputs go
    if ! check_for_files $2 ; then return $?; fi
    local WSDIR=$2/workspaces
    if ! matches_in $WSDIR '*1sigma*'
	then
	for dr in --down --up
	do
	    echo making ${dr#--} limits for $2
	    susy-fit-workspace.py $1 -o $WSDIR -c $2/configuration.yml \
		$EE $dr
	done
    fi
}

function makebg() {
    check_for_files $2
    if matches_in $2/workspaces "background*afterFit.root"; then
	return 0
    fi
    echo making bg fit for $2
    susy-fit-workspace.py $1 -o $2/workspaces -c $2/configuration.yml -fb $EE
    echo done bg fit for $2
}

function make_upper_limits() {
    # first arg: dir where workspace and upper-limits.yml live
    local WS_DIR=$1/workspaces
    local UL_FILE=$1/upper-limits.yml
    if ! matches_in $WS_DIR "*nominal.root"; then
	echo "no pre-fit workspaces found in $WS_DIR" >&2
	return 1
    fi
    if [[ ! -f $UL_FILE ]] ; then
	echo "making $UL_FILE"
	susy-fit-runfit.py $WS_DIR -c ul -o $UL_FILE
    fi

    local UL_OUTDIR=$OUTDIR/$1
    mkdir -p $UL_OUTDIR
    local CLS_FILE=$UL_OUTDIR/cls.yml
    if [[ ! -f $CLS_FILE ]] ; then
	echo "no $CLS_FILE found" >&2
	return 1
    fi
    local COMBINED_OUT=$UL_OUTDIR/combined-ul-cls.yml
    if [[ ! -f $COMBINED_OUT ]] ; then
	local TMP_UL=$TMP_DIR/upper-limits.yml
	susy-fit-cls-merge.py $UL_FILE -v $VETO_POINTS > $TMP_UL
	susy-fit-add-xsec.py -i $TMP_UL $DATASET_META
	susy-fit-cls-merge.py $TMP_UL $CLS_FILE > $COMBINED_OUT
    fi

    local PLOTDIR=$UL_OUTDIR/upper_limits
    mkdir -p $PLOTDIR
    local ALL_CONFIG="mct150 mct200 mct250"
    local FARG="$COMBINED_OUT --ul --external"
    local COMB_OUT=$PLOTDIR/scharm_combined.pdf
    if [[ ! -f $COMB_OUT ]]; then
	echo "drawing $COMB_OUT"
	susy-fit-draw-exclusion.py $FARG -r $ALL_CONFIG -o $COMB_OUT
    fi
    local CONFIG
    for CONFIG in $ALL_CONFIG ; do
	local OUT_PLT=$PLOTDIR/${CONFIG}.pdf
	if [[ ! -f $OUT_PLT ]]; then
	    echo "drawing $OUT_PLT"
	    susy-fit-draw-exclusion.py $FARG -r $CONFIG -o $OUT_PLT
	fi
    done
}

function make_model_independent_ul () {
    # first arg: directory containing workspaces
    # second arg: number of toys
    local TOYS=0
    local OUT_SUFFIX=asymptotic
    if (( $# >= 2 )) ; then
	TOYS=$2
	OUT_SUFFIX=${2}toys
    fi
    local DISCWS=discovery_nominal.root
    local WS_DIR=$1/workspaces
    if ! matches_in $WS_DIR $DISCWS; then
	echo "no discovery workspaces found in $WS_DIR" >&2
	exit 1
    fi
    local UL_DIR=$OUTDIR/$1/upper_limits
    local OUTFILE=$UL_DIR/model_independent_limit_${OUT_SUFFIX}.tex
    if [[ -f $OUTFILE ]] ; then
	return 0
    fi
    mkdir -p $UL_DIR

    local SHIT=pile-o-shit
    mkdir -p $SHIT
    (
	if cd $SHIT ; then
	    rm -f *
	else
	    exit 1
	fi
	local WS=$(find ../$WS_DIR -name $DISCWS)
	echo "making ul table $OUTFILE"
	local BS=bullshit.log
	UpperLimitTable.py $WS --n-toys $TOYS -o ultab.tex >| $BS 2>&1
	local BULLSHIT=$(wc -l $BS | cut -d ' ' -f 1)
	echo "made ul table with $BULLSHIT lines of bullshit"
    )
    cp $SHIT/ultab.tex $OUTFILE
}

function makepars() {
    # parameters:
    # 1: directory containing workspaces (also used to name output)
    # 2: regions to print when making tables
    # 3: subdirectory for outputs
    # 4: signal point used in workspace (defaults to background)
    # 5: fit configuration to use (default to all)

    echo making parameters for $1

    local WSHEAD=${4:-'background'}
    local DRAWARGS=''
    if [[ $WSHEAD != background ]]
    then
	DRAWARGS=-f
    fi

    local WSTAIL=afterFit.root
    local WSMATCH="*${WSHEAD}*_${WSTAIL}"
    if ! matches_in $1/workspaces $WSMATCH
	then
	echo "no matches to $WSMATCH $1/workspaces"
	return 1
    fi

    if (( $# >= 5 )); then
	local ALL_WS=$1/workspaces/$5/$WSMATCH
    else
	local ALL_WS=$1/workspaces/**/$WSMATCH
    fi
    local fit
    for fit in $ALL_WS
    do
	local odir=$OUTDIR/$1/$(dirname ${fit#*/workspaces/})
	if (( $# >= 2 )) ; then regs='-r '$2 ; fi
	if (( $# >= 3 ))
	then
	    odir=$odir/$3
	fi
	if ! matches_in $odir "*.tex"
	    then
	    echo "making systables in $odir"
	    mkdir -p $odir
	    susy-fit-systable.sh $fit -o $odir $regs $EE
	fi
	if ! matches_in $odir "*.pdf"
	    then
	    echo "drawing parameters in $odir"
	    local pars=$odir/fit-parameters.yml
	    local draw="susy-fit-draw-parameters.py -o $odir $EE $DRAWARGS"
	    susy-fit-results.py $fit | tee $pars | $draw
	fi
    done
    echo done making parameters for $1
}

# __________________________________________________________________________
# check for files

if [[ ! -f $SC_CLSFILE ]]
then
    echo "can't find $SC_CLSFILE for full exclusion, quitting" >&2
    exit 1
fi
if [[ $DO_UL && ! -f $DATASET_META ]] ; then
    echo "can't find $DATASET_META for upper-limits, quitting" >&2
    exit 1
fi
if [[ ! -f $MONOJET_LIMITS ]]
then
    echo "can't find $MONOJET_LIMITS for full exclusion, quitting" >&2
    exit 1
fi
if [[ ! -f $TTBAR_INPUT ]] ; then
    echo "can't find $TTBAR_INPUT, quitting" >&2
    exit 1
fi
if [[ ! -f $INPUT ]] ; then
    echo "can't find $INPUT, quitting" >&2
    exit 1
fi

# __________________________________________________________________________
# run the actual routines here

# run full fit (pass -f to make fit results for all workspaces)
DEFREGIONS=signal_mct150,cr_w,cr_z,cr_t
BGREGIONS=cr_w,cr_z,cr_t
VREGIONS=fr_mct,fr_mcc
SIGREGIONS=signal_mct150,signal_mct200,signal_mct250

makews_updown $INPUT full_exclusion
makelim $INPUT full_exclusion $SC_CLSFILE -f
drawlim full_exclusion
makepars full_exclusion $BGREGIONS bg_fit
makepars full_exclusion $DEFREGIONS srcr srcr
makepars full_exclusion $DEFREGIONS 400_200 400-200
makepars full_exclusion $DEFREGIONS 550_50 550-50
makepars full_exclusion $DEFREGIONS 250_50 250-50

# upper limit stuff
if [[ $DO_UL ]]
then
    make_upper_limits full_exclusion
    # make_model_independent_ul full_exclusion
    if (( $NTOYS > 0 )); then
	make_model_independent_ul full_exclusion $NTOYS
    fi
fi

# run systematics comparison
makelim $INPUT compare_systematics
drawlim compare_systematics
makebg $INPUT compare_systematics
makepars compare_systematics

# run crw comparison
makelim $INPUT compare_crw
drawlim compare_crw
makebg $INPUT compare_crw
makepars compare_crw $VREGIONS vr_fit
makepars compare_crw $BGREGIONS bg_fit

# other fit checks
NICKREGIONS=signal_mct150,cr_w_nicola,cr_z_nicola,cr_t_nicola
makelim $INPUT other_fits "" -f -s normal st_with_other nicolas
drawlimsubset other_fits single_t.pdf normal st_with_other
# drawlimsubset other_fits jes.pdf normal jes_breakdown
drawlimsubset other_fits nicolas.pdf normal nicolas
makepars other_fits $DEFREGIONS bg_fit
makepars other_fits $DEFREGIONS 400_200 400-200
makepars other_fits $NICKREGIONS nicolas

# run validation / sr plotting stuff
NICK_VR_PT=cr_w_nicola,cr_z_nicola,cr_t_nicola
NICK_VR_MET=cr_w_metola,cr_z_metola,cr_t_metola
makebg $INPUT vrsr
makepars vrsr $VREGIONS     vr_fit      background vrcrsr
makepars vrsr $SIGREGIONS   sr_fit      background vrcrsr
makepars vrsr $SIGREGIONS   sr_fit      background l1pt25
makepars vrsr signal_mct150 onesr_fit   background vrcrsr
makepars vrsr $NICK_VR_PT   nick_vr_pt  background vrcrsr
makepars vrsr $NICK_VR_MET  nick_vr_met background vrcrsr
makepars vrsr $SIGREGIONS   sr_fit      background nicola
makepars vrsr $SIGREGIONS   sr_fit      background metola

# ttbar reweighting check
makelim $TTBAR_INPUT ttbar_rw ""
makebg $TTBAR_INPUT ttbar_rw
draw-cls-between full_exclusion ttbar_rw '' ttbar_rw -r mct150 with_ttbar_rw
makepars ttbar_rw $VREGIONS vr_fit
makepars ttbar_rw $SIGREGIONS sr_fit
makepars ttbar_rw $BGREGIONS bg_fit

# zip up result
if [[ $ZIP ]]
then
    echo zipping
    tar czf ${OUTDIR}.tgz $OUTDIR
fi
