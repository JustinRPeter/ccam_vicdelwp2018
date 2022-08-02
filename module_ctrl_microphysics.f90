module module_ctrl_microphysics

  use cc_omp

#ifdef COSPP

  use cosp_kinds,          only: wp
  USE MOD_COSP_CONFIG,     ONLY: R_UNDEF,PARASOL_NREFL,LIDAR_NCAT,LIDAR_NTYPE,SR_BINS,    &
                                 N_HYDRO,RTTOV_MAX_CHANNELS,numMISRHgtBins,               &
                                 cloudsat_DBZE_BINS,LIDAR_NTEMP,calipso_histBsct,         &
                                 CFODD_NDBZE,      CFODD_NICOD,                           &
                                 CFODD_BNDRE,      CFODD_NCLASS,                          &
                                 CFODD_DBZE_MIN,   CFODD_DBZE_MAX,                        &
                                 CFODD_ICOD_MIN,   CFODD_ICOD_MAX,                        &
                                 CFODD_DBZE_WIDTH, CFODD_ICOD_WIDTH,                      &
                                 WR_NREGIME,                                              &
                                 numMODISTauBins,numMODISPresBins,                        &
                                 numMODISReffIceBins,numMODISReffLiqBins,                 &
                                 numISCCPTauBins,numISCCPPresBins,numMISRTauBins,         &
                                 ntau,modis_histTau,tau_binBounds,                        &
                                 modis_histTauEdges,tau_binEdges,                         &
                                 modis_histTauCenters,tau_binCenters,ntauV1p4,            &
                                 tau_binBoundsV1p4,tau_binEdgesV1p4, tau_binCentersV1p4,  &
                                 grLidar532_histBsct,atlid_histBsct,vgrid_zu,vgrid_zl,    &
                                 Nlvgrid_local  => Nlvgrid,                               &
                                 vgrid_z,cloudsat_preclvl
  use cosp_phys_constants, only: amw,amd,amO3,amCO2,amCH4,amN2O,amCO
  use mod_cosp_io,         only: nc_read_input_file,write_cosp2_output
  USE mod_quickbeam_optics,only: size_distribution,hydro_class_init,quickbeam_optics,     &
                                 quickbeam_optics_init,gases
  use quickbeam,           only: radar_cfg
  use mod_cosp,            only: cosp_init,cosp_optical_inputs,cosp_column_inputs,        &
                                 cosp_outputs,cosp_cleanUp,cosp_simulator
  USE mod_rng,             ONLY: rng_state, init_rng
  USE mod_scops,           ONLY: scops
  USE mod_prec_scops,      ONLY: prec_scops
  USE MOD_COSP_UTILS,      ONLY: cosp_precip_mxratio
  use cosp_optics,         ONLY: cosp_simulator_optics,lidar_optics,modis_optics,         &
                                 modis_optics_partition
  use mod_cosp_stats,      ONLY: COSP_CHANGE_VERTICAL_GRID
  !CHECK THIS AGGAIN
  USE MOD_LIDAR_SIMULATOR,     ONLY: alpha,beta,gamma
#endif

  implicit none
 
  private
  public ctrl_microphysics
  public cltcalipso_o,mr_ccice_o,cloudsat_Ze_tot,ncolumns

  public caso_ice, caso_liq
  public cloud_aerosol_mode, process_rate_mode
  !public mr_ccice_o,cloudsat_Ze_tot,ncolumns

  real, dimension(:,:), allocatable, save :: cltcalipso_o
  real, dimension(:,:), allocatable, save :: caso_ice, caso_liq
  real, dimension(:,:), allocatable, save :: mr_ccice_o
  real, dimension(:,:,:), allocatable, save :: cloudsat_Ze_tot
  integer, save :: ncolumns=20

  integer, save :: cloud_aerosol_mode = 0     ! 0=original, 1=standard feedback to aerosols
  integer, save :: process_rate_mode = 0      ! process rate for cloud microphysics (0=off)
#ifdef COSPP

  ! ====================================================================================================
  ! There are 2 input for COSP: vertical profile and optical inputs  
  ! Below is the input for the optical calculation
  ! https://github.com/CFMIP/COSPv2.0/blob/master/driver/run/cosp2_input_nl.um_global_model_levels.txt
  ! ====================================================================================================
  ! Input namelist fields
  integer, save  ::                            & !
    Npoints                   = 0,             & ! Number of gridpoints
    Nlevels                   = 1,            & ! Number of model vertical levels
    Npoints_it                = 0,             & ! Number of gridpoints to be processed in one
                                                 ! iteration
    Nlvgrid                   = 40,            & ! Number of vertical levels for statistical outputs
    !                                            ! (USE_VGRID=.true.)
    surface_radar             = 0,             & ! surface=1/spaceborne=0
    cloudsat_use_gas_abs      = 1,             & ! Include gaseous absorption (1=yes/0=no)
    cloudsat_do_ray           = 0,             & ! Calculate output Rayleigh (1=yes/0=no)
    lidar_ice_type            = 0,             & ! Ice particle shape in lidar calculations
                                                 ! (0=ice-spheres/1=ice-non-spherical)
    overlap                   = 3,             & ! Overlap type: 1=max, 2=rand, 3=max/rand
    isccp_topheight           = 1,             & ! ISCCP cloud top height
    isccp_topheight_direction = 2,             & ! ISCCP cloud top height direction
    rttov_platform            = 1,             & ! RTTOV: Satellite platform
    rttov_satellite           = 15,            & ! RTTOV: Satellite
    rttov_instrument          = 5,             & ! RTTOV: Instrument
    rttov_Nchannels           = 3                ! RTTOV: Number of channels to be computed
  real(wp), save ::                                  & !
    cloudsat_radar_freq       = 94.0,          & ! CloudSat radar frequency (GHz)
    cloudsat_k2               = -1,            & ! |K|^2, -1=use frequency dependent default
    rttov_ZenAng              = 50,            & ! RTTOV: Satellite Zenith Angle
    co2                       = 5.241e-04,     & ! CO2 mixing ratio
    ch4                       = 9.139e-07,     & ! CH4 mixing ratio
    n2o                       = 4.665e-07,     & ! n2o mixing ratio
    co                        = 2.098e-07        ! co mixing ratio
  logical, save ::                                   & !
    use_vgrid                 = .true.,        & ! Use fixed vertical grid for outputs?
    csat_vgrid                = .true.,        & ! CloudSat vertical grid?
    use_precipitation_fluxes  = .false.          ! True if precipitation fluxes are input to the
                                                 ! algorithm
  ! ====================================================================================================
  ! This is the vertical profile input
  ! ====================================================================================================
  integer, save     :: Nlon,Nlat,geomode
  real(wp), save    :: emsfc_lw  ! ! 10.5 micron emissivity of surface
  real(wp),dimension(:),allocatable,save,target:: &
    lon,                      & ! Longitude (deg)
    lat,                      & ! Latitude (deg)
    skt,                      & ! Skin temperature (K)
    surfelev,                 & ! Surface Elevation (m)
    landmask,                 & ! Land/sea mask (0/1)
    u_wind,                   & ! U-component of wind (m/s)
    v_wind,                   & ! V-component of wind (m/s)
    sunlit                      ! Sunlit flag
  real(wp),dimension(:,:),allocatable,save,target :: &
    p,p_inv,                  & ! Model pressure levels (pa)
    ph,ph_inv,                & ! Moddel pressure @ half levels (pa)
    zlev,zlev_inv,            & ! Model level height (m)
    zlev_half,zlev_half_inv,  & ! Model level height @ half-levels (m)
    Te,Te_inv,                & ! Temperature (K)
    qv,qv_inv,                & ! Specific humidity (kg/kg)
    rh,                       & ! Relative humidity (1)
    tca,tca_inv,              & ! Total cloud fraction (1)
    cca,cca_inv,              & ! Convective cloud fraction (1)
    mr_lsliq,mr_lsliq_inv,    & ! Mass mixing ratio for stratiform cloud liquid (kg/kg)
    mr_lsice,mr_lsice_inv,    & ! Mass mixing ratio for stratiform cloud ice (kg/kg)
    mr_ccliq,mr_ccliq_inv,    & ! Mass mixing ratio for convective cloud liquid (kg/kg)
    mr_ccice,mr_ccice_inv,    & ! Mass mixing ratio for convective cloud ice (kg/kg)
    mr_ozone,                 & ! Mass mixing ratio for ozone (kg/kg)
    fl_lsrain,fl_lsrain_inv,  & ! Precipitation flux (rain) for stratiform cloud (kg/m^2/s)
    fl_lssnow,fl_lssnow_inv,  & ! Precipitation flux (snow) for stratiform cloud (kg/m^2/s)
    fl_lsgrpl,fl_lsgrpl_inv,  & ! Precipitation flux (groupel) for stratiform cloud (kg/m^2/s)
    fl_ccrain,fl_ccrain_inv,  & ! Precipitation flux (rain) for convective cloud (kg/m^2/s)
    fl_ccsnow,fl_ccsnow_inv,  & ! Precipitation flux (snow) for convective cloud (kg/m^2/s)
    dtau_s,dtau_s_inv,        & ! 0.67micron optical depth (stratiform cloud) (1)
    dtau_c,dtau_c_inv,        & ! 0.67micron optical depth (convective cloud) (1)
    dem_s,dem_s_inv,          & ! 11micron emissivity (stratiform cloud)
    dem_c,dem_c_inv             ! 11microm emissivity (convective cloud)
  real(wp),dimension(:,:,:),allocatable,save,target :: &
    frac_out,                 & ! Subcolumn cloud cover (0/1)
    Reff,Reff2, Reff_inv              ! Subcolumn effective radius

  integer,dimension(RTTOV_MAX_CHANNELS), save :: rttov_Channels               ! RTTOV: Channel numbers
  real(wp),dimension(RTTOV_MAX_CHANNELS),save :: rttov_Surfem                 ! RTTOV: Surface emissivity
  character(len=64), save :: cloudsat_micro_scheme        ! Microphysical scheme used in cloudsat radar simulator

  ! ===================================================================================================
  ! Logical switch of which simulator we want to turn on
  ! ====================================================================================================
  logical, save :: Lcfaddbze94=.true.,Ldbze94=.true.,                                  &     ! Cloudsat
           Latb532=.true.,LcfadLidarsr532=.true.,Lclcalipso=.true.,                    &     !- CALIPSO
           Lclhcalipso=.true.,Lcllcalipso=.true.,Lclmcalipso=.true.,                   &
           Lcltcalipso=.true., LparasolRefl=.true.,                                    &
           Lclcalipsoliq=.true.,Lclcalipsoice=.true.,Lclcalipsoun=.true.,              &     ! CALIPSO phase diagnostics
           Lclcalipsotmp=.true.,Lclcalipsotmpliq=.true.,Lclcalipsotmpice=.true.,       &
           Lclcalipsotmpun=.true.,Lclhcalipsoliq=.true.,Lcllcalipsoliq=.true.,         &
           Lclmcalipsoliq=.true.,Lcltcalipsoliq=.true.,Lclhcalipsoice=.true.,          &
           Lcllcalipsoice=.true.,Lclmcalipsoice=.true.,Lcltcalipsoice=.true.,          &
           Lclhcalipsoun=.true.,Lcllcalipsoun=.true.,Lclmcalipsoun=.true.,             &
           Lcltcalipsoun=.true.,                                                       &  
           Lclopaquecalipso=.true.,Lclthincalipso=.true.,Lclzopaquecalipso=.true.,     &     ! CALIPSO OPAQ diagnostics
           Lclcalipsoopaque=.true.,Lclcalipsothin=.true.,Lclcalipsozopaque=.true.,     &
           Lclcalipsoopacity=.true.,Lclopaquetemp=.true.,Lclthintemp=.true.,           &
           Lclzopaquetemp=.true.,Lclopaquemeanz=.true., Lclthinmeanz=.true.,           &
           Lclthinemis=.true.,Lclopaquemeanzse=.true.,Lclthinmeanzse=.true.,           &
           Lclzopaquecalipsose=.true.,                                                 &
           LlidarBetaMol532gr=.true.,LcfadLidarsr532gr=.true.,Latb532gr=.true.,        &     ! GROUND LIDAR diagnostics
           LclgrLidar532=.true.,LclhgrLidar532=.true.,LcllgrLidar532=.true.,           &
           LclmgrLidar532=.true.,LcltgrLidar532=.true.,                                &
           LlidarBetaMol355=.true.,LcfadLidarsr355=.true.,Latb355=.true.,              &     ! ATLID diagnostics
           Lclatlid=.true.,Lclhatlid=.true.,Lcllatlid=.true.,                          &
           Lclmatlid=.true.,Lcltatlid=.true.,                                          &
           Lalbisccp=.false.,Lboxptopisccp=.false.,Lboxtauisccp=.false.,               &     !- ISCCP
           Lpctisccp=.false.,Lclisccp=.false.,Ltauisccp=.false.,                       &
           Lcltisccp=.false.,Lmeantbisccp=.false.,Lmeantbclrisccp=.false.,             &
           LclMISR=.true.,                                                             &     !- MISR
           Lclcalipso2=.true.,Lcltlidarradar=.true.,Lcloudsat_tcc=.true.,              &     !- Use lidar and radar
           Lcloudsat_tcc2=.true.,                                                      &
           Lfracout=.true.,LlidarBetaMol532=.true.,                                    &     !- These are provided for debugging or special purposes
           Lcltmodis=.true.,Lclwmodis=.true.,Lclimodis=.true.,                         &     !- MODIS
           Lclhmodis=.true.,Lclmmodis=.true.,Lcllmodis=.true.,                         &
           Ltautmodis=.true.,Ltauwmodis=.true.,Ltauimodis=.true.,                      &
           Ltautlogmodis=.true.,Ltauwlogmodis=.true.,Ltauilogmodis=.true.,             &
           Lreffclwmodis=.true.,Lreffclimodis=.true.,Lpctmodis=.true.,                 &
           Llwpmodis=.true.,Liwpmodis=.true.,Lclmodis=.true.,                          &
           Ltbrttov=.false.,                                                           &     !- RTTOV
           Lptradarflag0=.true.,Lptradarflag1=.true.,Lptradarflag2=.true.,             &     ! -CLOUDSAT precipitation frequency/occurence diagnostics
           Lptradarflag3=.true.,Lptradarflag4=.true.,Lptradarflag5=.true.,             &
           Lptradarflag6=.true.,Lptradarflag7=.true.,Lptradarflag8=.true.,             &
           Lptradarflag9=.true.,Lradarpia=.true.,                                      &
           Lwr_occfreq=.true.,                                                         &     !- CloudSat+MODIS joint diagnostics
           Lcfodd=.true.                    

  logical, save :: &
    lsingle     = .true.,  & ! True if using MMF_v3_single_moment CLOUDSAT microphysical scheme (default)
    ldouble     = .false., & ! True if using MMF_v3.5_two_moment CLOUDSAT microphysical scheme
    Lisccp      = .false. ,& ! Local on/off switch for simulators (used by initialization)
    lmodis      = .false., & !
    lmisr       = .false., & !
    lcalipso    = .false., & !
    lgrLidar532 = .false., & !
    latlid      = .false., & !
    lcloudsat   = .false., & !
    lrttov      = .false., & !
    lparasol    = .false.    !

  ! Local variable
  type(size_distribution), save :: &
    sd                ! Hydrometeor description
  type(radar_cfg), save :: &
    rcfg_cloudsat     ! Radar configuration
  type(cosp_outputs), save :: &
    cospOUT           ! COSP simulator outputs
  type(cosp_optical_inputs), save :: &
    cospIN            ! COSP optical (or derived?) fields needed by simulators
  type(cosp_column_inputs), save :: &
    cospstateIN       ! COSP model fields needed by simulators
  ! integer :: iChunk,nChunks,start_idx,end_idx,nPtsPerIt,ij
  character(len=256),dimension(100), save :: cosp_status

  ! Indices to address arrays of LS and CONV hydrometeors
  integer,parameter :: &
    I_LSCLIQ = 1, & ! Large-scale (stratiform) liquid
    I_LSCICE = 2, & ! Large-scale (stratiform) ice
    I_LSRAIN = 3, & ! Large-scale (stratiform) rain
    I_LSSNOW = 4, & ! Large-scale (stratiform) snow
    I_CVCLIQ = 5, & ! Convective liquid
    I_CVCICE = 6, & ! Convective ice
    I_CVRAIN = 7, & ! Convective rain
    I_CVSNOW = 8, & ! Convective snow
    I_LSGRPL = 9    ! Large-scale (stratiform) groupel

  ! Stratiform and convective clouds in frac_out (scops output).
  integer, parameter :: &
    I_LSC = 1, & ! Large-scale clouds
    I_CVC = 2    ! Convective clouds

  ! Microphysical settings for the precipitation flux to mixing ratio conversion
  real(wp),parameter,dimension(N_HYDRO) :: &
              ! LSL   LSI      LSR       LSS   CVL  CVI      CVR       CVS       LSG
    N_ax    = (/-1., -1.,     8.e6,     3.e6, -1., -1.,     8.e6,     3.e6,     4.e6/),&
    N_bx    = (/-1., -1.,      0.0,      0.0, -1., -1.,      0.0,      0.0,      0.0/),&
    alpha_x = (/-1., -1.,      0.0,      0.0, -1., -1.,      0.0,      0.0,      0.0/),&
    c_x     = (/-1., -1.,    842.0,     4.84, -1., -1.,    842.0,     4.84,     94.5/),&
    d_x     = (/-1., -1.,      0.8,     0.25, -1., -1.,      0.8,     0.25,      0.5/),&
    g_x     = (/-1., -1.,      0.5,      0.5, -1., -1.,      0.5,      0.5,      0.5/),&
    a_x     = (/-1., -1.,    524.0,    52.36, -1., -1.,    524.0,    52.36,   209.44/),&
    b_x     = (/-1., -1.,      3.0,      3.0, -1., -1.,      3.0,      3.0,      3.0/),&
    gamma_1 = (/-1., -1., 17.83725, 8.284701, -1., -1., 17.83725, 8.284701, 11.63230/),&
    gamma_2 = (/-1., -1.,      6.0,      6.0, -1., -1.,      6.0,      6.0,      6.0/),&
    gamma_3 = (/-1., -1.,      2.0,      2.0, -1., -1.,      2.0,      2.0,      2.0/),&
    gamma_4 = (/-1., -1.,      6.0,      6.0, -1., -1.,      6.0,      6.0,      6.0/)
  ! ====================================================================================================
#endif

contains

  !====================================================================================================
  ! SUBROUTINE ctrl_microphysics
  ! subroutine to call cloud microphysics
  ! The current available option are LEO and LIN microphysics
  !====================================================================================================
  subroutine ctrl_microphysics()

  use aerointerface                 ! Aerosol interface
  use arrays_m                      ! Atmosphere dyamics prognostic arrays
  use cc_mpi                        ! CC MPI routines
  use cc_omp                        ! CC OpenMP routines
  use cfrac_m                       ! Cloud fraction
  use cloudmod                      ! Prognostic cloud fraction
  use const_phys                    ! Physical constants
  use estab
  use filnames_m
  use kuocomb_m                     ! JLM convection
  use latlong_m
  use leoncld_mod                   ! Leo cloud microphysics
  use liqwpar_m                     ! Cloud water mixing ratios
  use map_m                         ! Grid map arrays
  use mgcloud_m , only : mg_2cond
  use module_aux_rad                ! ...
  use module_mp_sbu_ylin            ! Lin 2022 Scheme
  use morepbl_m                     ! Additional boundary layer diagnostics
  use newmpar_m                     ! Grid parameters
  use nharrs_m                      ! Non-hydrostatic atmosphere arrays
  !use outcdf
  use parm_m, only : dt,            &
                     idjd,iaero,    & 
                     iaero,         &
                     irest,         &
                     ktau, nwt      ! Model configuration
  use pbl_m
  use prec_m                        ! Precipitation
  use raddiag_m
  use screen_m
  use sflux_m 
  use sigs_m                        ! Atmosphere sigma levels
  use soil_m                        ! Soil and surface data
  use soilsnow_m
  use work3f_m                      ! Grid work arrays
  use vvel_m                        ! Additional vertical velocity
  implicit none
  !===================================================================================================
  !variable declaration for LEO cloud microphysics
  !====================================================================================================
  include 'kuocom.h'                ! Convection parameters
  integer :: tile, is, ie, k, ij,n
  integer :: idjd_t
  real, dimension(imax,kl) :: lcfrac, lgfrac
  real, dimension(imax,kl) :: lqg, lqgrg, lqlg, lqfg, lqlrad, lqfrad, lqrg, lqsng, lrfrac, lsfrac, lt
  real, dimension(imax,kl) :: ldpsldt, lnettend, lstratcloud, lclcon, lcdrop, lrhoa
  real, dimension(imax,kl) :: lqccon
  real, dimension(imax,kl) :: lrkmsave, lrkhsave
  real, dimension(imax,kl) :: lfluxr, lfluxm, lfluxf, lfluxi, lfluxs, lfluxg
  real, dimension(imax,kl) :: lqevap, lqsubl, lqauto, lqcoll, lqaccr, lqaccf
  real, dimension(imax,kl) :: lppfevap, lppfmelt, lppfprec, lppfsnow, lppfsubl
  real, dimension(imax,kl) :: lpplambs, lppmaccr, lppmrate, lppqfsedice, lpprfreeze, lpprscav
  real, dimension(imax,kl) :: lvi, lvs, lvg
  real, dimension(imax,kl) :: lplambs, lqfsedice, lprscav
  real, dimension(ifull,kl) :: clcon, cdrop
  real, dimension(ifull,kl) :: fluxr, fluxm, fluxf, fluxi, fluxs, fluxg
  real, dimension(ifull,kl) :: fevap, fsubl, fauto, fcoll, faccr, faccf
  real, dimension(ifull,kl) :: vi, vs, vg
  real, dimension(ifull,kl) :: dz, rhoa
  real fcol, fr, qtot, xic, xsn, xgr, vave, alph
  logical :: mydiag_t
  
  !====================================================================================================
  !variable declaration for LIN cloud microphysics
  !====================================================================================================
  !intent(in)
  integer                  :: ids,ide,jds,jde,kds,kde,ims,ime,jms,jme,kms,kme, &
                              its,ite,jts,jte,kts,kte
  real                     :: dt_in
  real                     :: ccn0 !1.0E8
  real(kind=8), dimension(imax)    :: ht
  real, dimension(imax,kl) :: w
  real, dimension(imax,kl) :: rho, pii, z, zlevv,p_lin, dz8w
  !intent in out
  real, dimension(imax)    :: RAINNC,RAINNCV
  real, dimension(imax)    :: SNOWNC,SNOWNCV
  real, dimension(imax,kl) :: th,qv_lin,qi,ql,qs,qr
  real, dimension(imax,kl) :: nnr,nni,nns
  real, dimension(imax,kl) :: Ri3D
  real, dimension(imax,kl) :: nn !nc,nr,ni,ns,nn
  ! intent(out)
  real, dimension(imax,kl) :: precr,preci,precs,eradc,eradi,erads,eradr
  ! local variables
  integer                  :: min_q, max_q
  real, dimension(imax)    :: rain, snow,ice
  real, dimension(kl)      :: qgz
  real(kind=8), dimension(kl) :: qvz,qlz,qrz,qiz,qsz,thz,tothz,rhoz,orhoz,sqrhoz
  real(kind=8), dimension(kl) :: zfluxr,zfluxi,zfluxs,zfluxg,zfluxm,&
                                 zfluxf,zfevap,zfsubl,zfauto,zfcoll,&
                                 zfaccr,zvi,zvs,zvg                         !for aerosol scheme
  real(kind=8), dimension(kl) :: zpsnow,zpsaut,zpsfw,zpsfi,zpraci,  &       !process rate to understand cloud microphysics
                                 zpiacr,zpsaci,zpsacw,zpsdep,       &
                                 zpssub,zpracs,zpsacr,zpsmlt,       &
                                 zpsmltevp,zprain,zpraut,zpracw,    &
                                 zprevp,zpgfr,zpvapor,zpclw,        &
                                 zpladj,zpcli,zpimlt,zpihom,        &
                                 zpidw,zpiadj,zqschg
  real, dimension(imax,kl) ::  zzpsnow,zzpsaut,zzpsfw,zzpsfi,zzpraci, &   !process rate to understand cloud microphysics
                               zzpiacr,zzpsaci,zzpsacw,zzpsdep,       &
                               zzpssub,zzpracs,zzpsacr,zzpsmlt,       &
                               zzpsmltevp,zzprain,zzpraut,zzpracw,    &
                               zzprevp,zzpgfr,zzpvapor,zzpclw,        &
                               zzpladj,zzpcli,zzpimlt,zzpihom,        &
                               zzpidw,zzpiadj,zzqschg

  real(kind=8), dimension(kl) :: prez,zz,dzw,precrz,preciz,precsz
  real(kind=8), dimension(kl) :: EFFC1D,EFFI1D,EFFS1D,EFFR1D
  real(kind=8), dimension(kl) :: riz
  real                     :: rhoe_s
  real(kind=8)             :: pptice, pptrain, pptsnow
  integer                  :: i,j,m,iq    !,k
  real, dimension(kl)      :: nnz
  real(kind=8), dimension(kl) :: ncz,nrz,niz,nsz
  real, dimension(imax,kl) :: t_imax
  real, dimension(imax)    :: ps_imax
  !====================================================================================================
  
  real, dimension(imax,kl)    :: prf
  real, dimension(imax)       :: prf_temp 
  real :: maxlintime
  real(kind=8) :: tdt
  integer :: njumps
#ifdef COSPP
  ! for CCAM
  integer                     :: end_idx, start_idx, nPtsPerIt, iii, jjj, kkk, cnttt
  real                        :: rong, year, kdate, month
  real, dimension(imax)       :: uas, vas, umag, seaice
  real, dimension(1:kl)       :: delh ! , sigh !, sig
  real, dimension(imax,1:kl)  :: phalf
  real, dimension(imax,kl)    :: qsatg    !Saturation mixing ratio
  real, dimension(imax,kl) :: r_cfrac, r_qlrad, r_qfrad, r_prf, r_t
  real, dimension(imax,kl) :: r_cdrop
  real(kind=8), dimension(imax,kl) :: Rdrop, Rice, conl, coni
  real, dimension(imax,kl,N_HYDRO) :: Reff_imax
  real :: slwp, siwp, sdrop, sice
  real :: tau_ice
  real, dimension(4)  :: tau_liq
  real :: k_liq, k_ice
  real, dimension(imax,kl) :: cloud_tau, cloud_emiss
#endif

  !----------------------------------------------------------------------------
  ! Prepare inputs for /loud microphysics

  !$omp do schedule(static) private(is,ie),                                             &
  !$omp private(k,lrhoa,lcdrop,lclcon)
  do tile = 1,ntiles
    is = (tile-1)*imax + 1
    ie = tile*imax
    ! Calculate droplet concentration from aerosols (for non-convective faction of grid-box)
    do k = 1,kl
      lrhoa(1:imax,k) = ps(is:ie)*sig(k)/(rdry*t(is:ie,k))
      rhoa(is:ie,k) = lrhoa(:,k)
      dz(is:ie,k) = -rdry*dsig(k)*t(is:ie,k)/(grav*sig(k))
    end do
    call aerodrop(is,lcdrop,lrhoa,outconv=.TRUE.)
    cdrop(is:ie,1:kl) = lcdrop(1:imax,1:kl)

    ! Calculate convective cloud fraction
    call convectivecloudfrac(lclcon,kbsav(is:ie),ktsav(is:ie),condc(is:ie))
    clcon(is:ie,1:kl) = lclcon(1:imax,1:kl)
  end do
  !$omp end do nowait

  !----------------------------------------------------------------------------
  ! Update cloud fraction

  !$omp do schedule(static) private(is,ie),                                             &
  !$omp private(lcfrac),                                                                &
  !$omp private(lqccon,lqfg,lqfrad,lqg,lqlg,lqlrad,lt),                                 &
  !$omp private(ldpsldt,lnettend,lstratcloud,lclcon,lcdrop,lrkmsave,lrkhsave),          &
  !$omp private(idjd_t,mydiag_t)
  do tile = 1,ntiles
    is = (tile-1)*imax + 1
    ie = tile*imax

    idjd_t = mod(idjd-1,imax) + 1
    mydiag_t = ((idjd-1)/imax==tile-1).AND.mydiag

    lcfrac   = cfrac(is:ie,:)
    lqg      = qg(is:ie,:)
    lqlg     = qlg(is:ie,:)
    lqfg     = qfg(is:ie,:)
    lqlrad   = qlrad(is:ie,:)
    lqfrad   = qfrad(is:ie,:)
    lt       = t(is:ie,:)
    ldpsldt  = dpsldt(is:ie,:)
    lclcon   = clcon(is:ie,:)
    lcdrop   = cdrop(is:ie,:)
    lstratcloud = stratcloud(is:ie,:)
    if ( ncloud==4 .or. (ncloud>=10.and.ncloud<=13) .or. ncloud==110 ) then
      lnettend    = nettend(is:ie,:)
      lrkmsave    = rkmsave(is:ie,:)
      lrkhsave    = rkhsave(is:ie,:)
    end if

    call update_cloud_fraction(lcfrac,kbsav(is:ie),ktsav(is:ie),land(is:ie),                    &
                ps(is:ie),lqccon,lqfg,lqfrad,lqg,lqlg,lqlrad,lt,                                &
                ldpsldt,lnettend,lstratcloud,lclcon,lcdrop,em(is:ie),pblh(is:ie),idjd_t,        &
                mydiag_t,ncloud,nclddia,ldr,rcrit_l,rcrit_s,rcm,cld_decay,                      &
                vdeposition_mode,tiedtke_form,lrkmsave,lrkhsave,imax,kl)

    cfrac(is:ie,:) = lcfrac
    qccon(is:ie,:) = lqccon
    qg(is:ie,:)    = lqg
    qlg(is:ie,:)   = lqlg
    qfg(is:ie,:)   = lqfg
    qlrad(is:ie,:) = lqlrad
    qfrad(is:ie,:) = lqfrad
    t(is:ie,:)     = lt
    stratcloud(is:ie,:) = lstratcloud
    if ( ncloud==4 .OR. (ncloud>=10.AND.ncloud<=13) .or. ncloud==110 ) then
      nettend(is:ie,:)    = lnettend
    end if
  end do
  !$omp end do nowait



  !----------------------------------------------------------------------------
  ! Update cloud condensate

  select case ( interp_ncloud(ldr,ncloud) )
    case("LEON")
  
      !$omp do schedule(static) private(is,ie),                                           &
      !$omp private(lgfrac,lrfrac,lsfrac,lqfg,lqg,lqgrg,lqlg,lqrg,lqsng,lt,lstratcloud),  &
      !$omp private(lclcon,lcdrop,lfluxr,lfluxm,lfluxf,lfluxi,lfluxs,lfluxg),             &
      !$omp private(lqevap,lqsubl,lqauto,lqcoll,lqaccr,lqaccf,lvi,lvs,lvg),               &
      !$omp private(lplambs,lqfsedice,lprscav),                                           &
      !$omp private(idjd_t,mydiag_t)
      do tile = 1,ntiles
        is = (tile-1)*imax + 1
        ie = tile*imax

        idjd_t = mod(idjd-1,imax) + 1
        mydiag_t = ((idjd-1)/imax==tile-1).AND.mydiag

        lgfrac   = gfrac(is:ie,:)
        lrfrac   = rfrac(is:ie,:)
        lsfrac   = sfrac(is:ie,:)
        lqg      = qg(is:ie,:)
        lqgrg    = qgrg(is:ie,:)
        lqlg     = qlg(is:ie,:)
        lqfg     = qfg(is:ie,:)
        lqrg     = qrg(is:ie,:)
        lqsng    = qsng(is:ie,:)
        lt       = t(is:ie,:)
        lcdrop   = cdrop(is:ie,:)
        lstratcloud = stratcloud(is:ie,:)

        call leoncld_work(condg(is:ie),conds(is:ie),condx(is:ie),lgfrac,ktsav(is:ie),         &
              lppfevap,lppfmelt,lppfprec,lppfsnow,lppfsubl,                                   &
              lpplambs,lppmaccr,lppmrate,lppqfsedice,lpprfreeze,lpprscav,precip(is:ie),       &
              ps(is:ie),lqfg,lqg,lqgrg,lqlg,lqrg,lqsng,lrfrac,lsfrac,lt,                      &
              lstratcloud,lcdrop,lfluxr,lfluxm,lfluxf,lfluxi,lfluxs,lfluxg,lqevap,lqsubl,     &
              lqauto,lqcoll,lqaccr,lvi,lvs,lvg,                                               &
              idjd_t,mydiag_t,ncloud,nevapls,ldr,rcm,imax,kl)
        gfrac(is:ie,:) = lgfrac
        rfrac(is:ie,:) = lrfrac
        sfrac(is:ie,:) = lsfrac
        qg(is:ie,:)    = lqg
        qlg(is:ie,:)   = lqlg
        qfg(is:ie,:)   = lqfg
        qrg(is:ie,:)   = lqrg
        qsng(is:ie,:)  = lqsng
        qgrg(is:ie,:)  = lqgrg
        t(is:ie,:)     = lt
        stratcloud(is:ie,:) = lstratcloud
        fluxr(is:ie,:) = lfluxr/dt
        fluxm(is:ie,:) = lfluxm/dt
        fluxf(is:ie,:) = lfluxf/dt
        fluxi(is:ie,:) = lfluxi/dt
        fluxs(is:ie,:) = lfluxs/dt
        fluxg(is:ie,:) = lfluxg/dt
        fevap(is:ie,:) = lqevap(:,:)*rhoa(is:ie,:)*dz(is:ie,:)/dt
        fsubl(is:ie,:) = lqsubl(:,:)*rhoa(is:ie,:)*dz(is:ie,:)/dt
        fauto(is:ie,:) = lqauto(:,:)*rhoa(is:ie,:)*dz(is:ie,:)/dt
        fcoll(is:ie,:) = lqcoll(:,:)*rhoa(is:ie,:)*dz(is:ie,:)/dt
        faccr(is:ie,:) = lqaccr(:,:)*rhoa(is:ie,:)*dz(is:ie,:)/dt
        !faccf(is:ie,:) = lqaccf(:,:)*rhoa(is:ie,:)*dz(is:ie,:)/dt
        vi(is:ie,:) = lvi
        vs(is:ie,:) = lvs
        vg(is:ie,:) = lvg
        ! backwards compatible data for aerosols
        if ( abs(iaero)>=2 ) then
          if (myid == 0 .and. tile==1 ) then
            print*, 'fluxr :', minval(fluxr(is:ie,:)), maxval(fluxr(is:ie,:))
            print*, 'fluxm :', minval(fluxm(is:ie,:)), maxval(fluxm(is:ie,:))
            print*, 'fluxf :', minval(fluxf(is:ie,:)), maxval(fluxf(is:ie,:))
            print*, 'fluxi :', minval(fluxi(is:ie,:)), maxval(fluxi(is:ie,:))
            print*, 'fluxs :', minval(fluxs(is:ie,:)), maxval(fluxs(is:ie,:))
            print*, 'fluxg :', minval(fluxg(is:ie,:)), maxval(fluxg(is:ie,:))
            print*, 'fevap :', minval(fevap(is:ie,:)), maxval(fevap(is:ie,:))
            print*, 'fsubl :', minval(fsubl(is:ie,:)), maxval(fsubl(is:ie,:))
            print*, 'fauto :', minval(fauto(is:ie,:)), maxval(fauto(is:ie,:))
            print*, 'fcoll :', minval(fcoll(is:ie,:)), maxval(fcoll(is:ie,:))
            print*, 'faccr :', minval(faccr(is:ie,:)), maxval(faccr(is:ie,:))
            print*, 'vi    :', minval(vi(is:ie,:)), maxval(vi(is:ie,:))
            print*, 'vs    :', minval(vs(is:ie,:)), maxval(vs(is:ie,:))
            print*, 'vg    :', minval(vg(is:ie,:)), maxval(vg(is:ie,:))
          end if
          ppfprec(is:ie,1) = 0.   ! at TOA
          ppfmelt(is:ie,1) = 0.   ! at TOA
          ppfsnow(is:ie,1) = 0.   ! at TOA
          pprfreeze(is:ie,1) = 0.  ! at TOA
          do k = 1,kl-1
            ppfprec(is:ie,kl+1-k) = (lfluxr(:,k+1)+lfluxm(:,k)-lfluxf(:,k))/dt
            ppfmelt(is:ie,kl+1-k) = lfluxm(:,k)/dt
            ppfsnow(is:ie,kl+1-k) = (lfluxi(:,k+1)+lfluxs(:,k+1)+lfluxg(:,k+1) &
                                    -lfluxm(:,k)+lfluxf(:,k))/dt
            pprfreeze(is:ie,kl+1-k) = lfluxf(:,k)/dt
          end do
          do k = 1,kl
            ppfevap(is:ie,kl+1-k) = lqevap(:,k)*rhoa(is:ie,k)*dz(is:ie,k)/dt
            ppfsubl(is:ie,kl+1-k) = lqsubl(:,k)*rhoa(is:ie,k)*dz(is:ie,k)/dt
            pplambs(is:ie,kl+1-k) = lplambs(:,k)
            ppmaccr(is:ie,kl+1-k) = lqaccr(:,k)/dt
            ppmrate(is:ie,kl+1-k) = (lqauto(:,k)+lqcoll(:,k))/dt
            ppqfsedice(is:ie,kl+1-k) = lqfsedice(:,k)
            pprscav(is:ie,kl+1-k) = lprscav(:,k)
          end do
        end if  

      end do
      !$omp end do nowait

    case("LIN")

      if ( myid==0 ) then
        write(6,*) "LIN microphysics ",ncloud
      end if  
      
      !if ( myid==0 ) then
      !  write(6,*) "Waiting before 1st LIN barrier"
      !endif
      !call ccmpi_barrier(comm_world)
      !if ( myid==0 ) then
      !  write(6,*) "After 1st LIN barrier"
      !endif


      !check to ensure again if W is in used somewhere
      !check if Ri only calc here
      ccn0 = 250     
      riz  = 0
      dt=dt !dt_in 
      rhoe_s=1.29
      !t_imax = -300.
      
      maxlintime = 120.
      njumps = int(dt/(maxlintime+0.01)) + 1
      tdt    = real(dt,8)/real(njumps,8)
      do tile = 1, ntiles
        is = (tile-1)*imax + 1
        ie = tile*imax

        ! prepare CCAM input for Lin 2022 microphysics here
        its = is
        ite = ie
        kts = 1
        kte = kl

        ! done input for LIN 2022 microphysics
        ! now do the loop in LIN
        do iq = its, ite
          ! iq is for ifull arrays  iq>=1 and iq<=ifull
          ! i is for imax arrays
          i = iq - its + 1 ! i>=1 and i<=imax

          zlevv(i,1)   = bet(1)*t(iq,1)/grav + zs(iq)/grav
          do m=2,kl
            zlevv(i,m)   = zlevv(i,m-1) + (bet(m)*t(iq,m)+betm(m)*t(iq,m-1))/grav
          end do
          ht(i) = real( zs(iq)/grav, 8 )

          !!- write data from 3-D to 1-D
          do k = kts, kte

            ! unpack from iq to i
            qvz(k)   = real(qg(iq,k),8)   !qv(iq,k)
            qlz(k)   = real(qlg(iq,k),8)  !ql(iq,k)
            qrz(k)   = real(qrg(iq,k),8)  !qr(iq,k)
            qiz(k)   = real(qfg(iq,k),8)  !qi(iq,k)
            qsz(k)   = real(qsng(iq,k),8) !qs(iq,k)
            t_imax(i,k) = t(iq,k)
            ps_imax(i) = ps(iq)

            ! ----------------
            ! all arrays are imax below this line

            prf_temp(i) = ps_imax(i)*sig(k)
            prf(i,k)    = 0.01*prf_temp(i)                        ! ps is SI units
            !rhoa(i,k)   = prf_temp(i)/(rdry*t_imax(i,k))          ! air density
            !dz(i,k)     = -rdry*dsig(k)*t_imax(i,k)/(grav*sig(k)) ! level thickness in metres
            !dz(i,k)     = min( max(dz(i,k), 1.), 2.e4 )
            tothz(k)    = real( (prf(i,k)/1000.)**(rdry/cp), 8 )    !pii(i,k)
            !thz(k)      = t_imax(i,k) * (1000. / prf(i,k))**(rdry/cp)           !th(i,k)
            thz(k)      = real(t_imax(i,k),8) / tothz(k)
            rhoz(k)     = real(rhoa(i,k),8)        !rho(i,k)
            orhoz(k)    = 1._8/rhoz(k)
            prez(k)     = real( sig(k)*ps_imax(i), 8 )     !ps(i,k) !p(i,k)
            ! sqrhoz(k)=sqrt(rhoe_s*orhoz(k))
            ! no density dependence of fall speed as Note #5, you can turn it on to increase fall speed at low pressure.
            sqrhoz(k)   = 1.0_8

            zz(k)       = real( zlevv(i,k), 8 )          !z(i,k)
            dzw(k)      = real( dz(i,k), 8 )  !dz8w(i,k)
            ncz(k)      = 0. !real( nc(iq,k), 8 )
            nrz(k)      = 0. !real( nr(iq,k), 8 )
            niz(k)      = 0. !real( ni(iq,k), 8 )
            nsz(k)      = 0. !real( ns(iq,k), 8 )
          end do ! k loop

          pptrain=0._8
          pptsnow=0._8
          pptice=0._8
#ifdef sonny_debug
          if (myid == 0 .and. tile==1 ) then        
            print*, '================= START input to LIN 2022 =================================='
            print*, 'qvz      :', minval(qvz(:)), maxval(qvz(:))
            print*, 'qlz      :', minval(qlz(:)), maxval(qlz(:))
            print*, 'qrz      :', minval(qrz(:)), maxval(qrz(:))
            print*, 'qiz      :', minval(qiz(:)), maxval(qiz(:))
            print*, 'qsz      :', minval(qsz(:)), maxval(qsz(:))
            print*, 'thz      :', minval(thz(:)), maxval(thz(:))
            print*, 't_imax   :', minval(t_imax(i,:)), maxval(t_imax(i,:))
            print*, 'ps_imax  :', ps_imax(i)
            print*, 'rhoa     :', minval(rhoa(i,:)), maxval(rhoa(i,:))
            print*, 'tothz    :', minval(tothz(:)), maxval(tothz(:)) 
            print*, 'zlevv    :', minval(zlevv(i,:)), maxval(zlevv(i,:))
            print*, '================= END input to LIN 2022 ===================================='
          end if
#endif
          ! Use sub time-step if required
          do n = 1,njumps
            CALL clphy1d_ylin(tdt, qvz, qlz, qrz, qiz, qsz,   &
                           thz, tothz, rhoz, orhoz, sqrhoz,   &
                           prez, zz, dzw, ht(i),              &
                           precrz, preciz, precsz,            & !zdc 20220116
                           EFFC1D, EFFI1D, EFFS1D, EFFR1D,    & !zdc 20220208
                           pptrain, pptsnow, pptice,          &
                           kts, kte, i, j, riz,               &
                           ncz, nrz, niz, nsz,                & 
                           zfluxr,zfluxi,zfluxs,zfluxg,zfluxm,&
                           zfluxf,zfevap,zfsubl,zfauto,zfcoll,&
                           zfaccr,zvi,zvs,zvg,                & !aerosol scheme
                           zpsnow,zpsaut,zpsfw,zpsfi,zpraci,  & !process rate to understand cloud microphysics
                           zpiacr,zpsaci,zpsacw,zpsdep,       &
                           zpssub,zpracs,zpsacr,zpsmlt,       &
                           zpsmltevp,zprain,zpraut,zpracw,    &
                           zprevp,zpgfr,zpvapor,zpclw,        &
                           zpladj,zpcli,zpimlt,zpihom,        &
                           zpidw,zpiadj,zqschg)
          end do 
#ifdef sonny_debug          
          if (myid == 0 .and. tile==1 ) then
          print*, '================= START output of LIN 2022 =================================='
          print*, 'qvz      :', minval(qvz(:)), maxval(qvz(:))
          print*, 'qlz      :', minval(qlz(:)), maxval(qlz(:))
          print*, 'qrz      :', minval(qrz(:)), maxval(qrz(:))
          print*, 'qiz      :', minval(qiz(:)), maxval(qiz(:))
          print*, 'qsz      :', minval(qsz(:)), maxval(qsz(:))
          print*, 'thz      :', minval(thz(:)), maxval(thz(:))
          print*, 't_imax   :', minval(t_imax(i,:)), maxval(t_imax(i,:))
          print*, 'ps_imax  :', ps_imax(i)
          print*, 'rhoa     :', minval(rhoa(i,:)), maxval(rhoa(i,:))
          print*, 'tothz    :', minval(tothz(:)), maxval(tothz(:))
          print*, 'zlevv    :', minval(zlevv(i,:)), maxval(zlevv(i,:))
          if (maxval(riz) > 0.) then
          print*, 'riz      :', minval(riz(:)), maxval(riz(:)) 
          end if
          print*, 'precrz   :', minval(precrz(:)),maxval(precrz(:))
          print*, 'preciz   :', minval(preciz(:)),maxval(preciz(:))
          print*, 'precsz   :', minval(precsz(:)),maxval(precsz(:))
          print*, 'EFFC1D   :', minval(EFFC1D(:)), maxval(EFFC1D(:))
          print*, 'EFFI1D   :', minval(EFFI1D(:)), maxval(EFFI1D(:)) 
          print*, 'EFFS1D   :', minval(EFFS1D(:)), maxval(EFFS1D(:))
          print*, 'EFFR1D   :', minval(EFFR1D(:)), maxval(EFFR1D(:))
          print*, 'ncz      :', minval(ncz(:)), maxval(ncz(:))
          print*, 'nrz      :', minval(nrz(:)), maxval(nrz(:))
          print*, 'niz      :', minval(niz(:)), maxval(niz(:))
          print*, 'nsz      :', minval(nsz(:)), maxval(nsz(:))
          print*, '================= END output of LIN 2022 ===================================='
          end if
#endif
          ! Precipitation from cloud microphysics -- only for one time step
          ! unit is transferred from m to mm
          rain(i)= pptrain
          snow(i)= pptsnow
          ice(i) = pptice
          RAINNCV(i)= real( pptrain + pptsnow + pptice )
          RAINNC(i) = RAINNC(i) + real( pptrain + pptsnow + pptice )
          SNOWNCV(i)= real( pptsnow + pptice )
          SNOWNC(i) = SNOWNC(i) + real( pptsnow + pptice )
          !- update data from 1-D back to 3-D
          do k = kts, kte
            qv_lin(i,k)=real(qvz(k))
            ql(i,k)=real(qlz(k))
            qr(i,k)=real(qrz(k))
            qi(i,k)=real(qiz(k))
            qs(i,k)=real(qsz(k))
            ri3d(i,k)=real(riz(k))
            
            !nc(i,k)=ncz(k)
            nnr(i,k)=nrz(k)
            nni(i,k)=niz(k)
            nns(i,k)=nsz(k)                   !zdc 20220116
            th(i,k)=real( thz(k) * tothz(k) )
            
            precr(i,k)=real(precrz(k))
            preci(i,k)=real(preciz(k))
            precs(i,k)=real(precsz(k))

            eradc(i,k) = real(EFFC1D(k))      ! BAW ADD FOR WRF-COSP zdc
            eradi(i,k) = real(EFFI1D(k))
            erads(i,k) = real(EFFS1D(k))
            eradr(i,k) = real(EFFR1D(k))

            fluxr(i,k) = zfluxr(k)            ! flux for aerosol calculation
            fluxm(i,k) = zfluxm(k)
            fluxf(i,k) = zfluxf(k)
            fluxi(i,k) = zfluxi(k)
            fluxs(i,k) = zfluxs(k)
            fluxg(i,k) = zfluxg(k)
            fevap(i,k) = zfevap(k)
            fsubl(i,k) = zfsubl(k)
            fauto(i,k) = zfauto(k)
            fcoll(i,k) = zfcoll(k)
            faccr(i,k) = zfaccr(k)
            vi(i,k) = zvi(k)
            vs(i,k) = zvs(k)
            vg(i,k) = zvg(k)

            if (process_rate_mode > 0) then 
              zzpsnow(i,k)   = real(zpsnow(k))   !process rate to understand cloud microphysics
              zzpsaut(i,k)   = real(zpsaut(k))
              zzpsfw(i,k)    = real(zpsfw(k))
              zzpsfi(i,k)    = real(zpsfi(k))
              zzpraci(i,k)   = real(zpraci(k))
              zzpiacr(i,k)   = real(zpiacr(k))
              zzpsaci(i,k)   = real(zpsaci(k))
              zzpsacw(i,k)   = real(zpsacw(k))
              zzpsdep(i,k)   = real(zpsdep(k))
              zzpssub(i,k)   = real(zpssub(k))
              zzpracs(i,k)   = real(zpracs(k))
              zzpsacr(i,k)   = real(zpsacr(k))
              zzpsmlt(i,k)   = real(zpsmlt(k))
              zzpsmltevp(i,k)= real(zpsmltevp(k))
              zzprain(i,k)   = real(zprain(k))
              zzpraut(i,k)   = real(zpraut(k))
              zzpracw(i,k)   = real(zpracw(k))
              zzprevp(i,k)   = real(zprevp(k))
              zzpgfr(i,k)    = real(zpgfr(k))
              zzpvapor(i,k)  = real(zpvapor(k))
              zzpclw(i,k)    = real(zpclw(k))
              zzpladj(i,k)   = real(zpladj(k))
              zzpcli(i,k)    = real(zpcli(k))
              zzpimlt(i,k)   = real(zpimlt(k))
              zzpihom(i,k)   = real(zpihom(k))
              zzpidw(i,k)    = real(zpidw(k))
              zzpiadj(i,k)   = real(zpiadj(k))
              zzqschg(i,k)   = real(zqschg(k)) 
            end if
          end do !k loop
        !end do   !i loop
  
        !do iq = its,ite
          !i = iq - its + 1
          do k = kts, kte
            t(iq,k) = th(i,k)
            if ( t(iq,k) > 10000. ) then
              print*, t(iq,k), th(i,k), iq, i, k, tile
            end if 
            gfrac(iq,k) = 0.  !lgfrac   ! graupel area fraction
            if ( qr(i,k)>0. ) then
              rfrac(iq,k) = 1.  !lrfrac   ! rain area fraction
            else
              rfrac(iq,k) = 0.
            end if
            if ( qs(i,k)>0. ) then
              sfrac(iq,k) = 1.
            else
              sfrac(iq,k) = 0.
            end if
            qg(iq,k)    = qv_lin(i,k)              !lqg    ! qv mixing ratio
            qlg(iq,k)   = ql(i,k)                  !lqlg   ! ql mixing ratio
            qfg(iq,k)   = qi(i,k)                  !lqfg   ! qf mixing ratio (ice)
            qrg(iq,k)   = qr(i,k)                  !lqrg   ! qr mixing ratio (rain)
            qsng(iq,k)  = qs(i,k)*(1-ri3d(i,k))     !lqsng  ! qs mixing ratio (snow)
            qgrg(iq,k)  = qs(i,k)*ri3d(i,k)        !lqgrg  ! qg mixing ration (graupel)
            stratcloud(iq,k) = cfrac(iq,k)

            !nc(iq,k)=ncz(k)
            nr(iq,k)=nnr(i,k)
            ni(iq,k)=nni(i,k)
            ns(iq,k)=nns(i,k)    !zdc 20220116

            if (process_rate_mode > 0) then
              psnow(iq,k)   = zzpsnow(i,k)   !process rate to understand cloud microphysics
              psaut(iq,k)   = zzpsaut(i,k)
              psfw(iq,k)    = zzpsfw(i,k)
              psfi(iq,k)    = zzpsfi(i,k)
              praci(iq,k)   = zzpraci(i,k)
              piacr(iq,k)   = zzpiacr(i,k)
              psaci(iq,k)   = zzpsaci(i,k)
              psacw(iq,k)   = zzpsacw(i,k)
              psdep(iq,k)   = zzpsdep(i,k)
              pssub(iq,k)   = zzpssub(i,k)
              pracs(iq,k)   = zzpracs(i,k)
              psacr(iq,k)   = zzpsacr(i,k)
              psmlt(iq,k)   = zzpsmlt(i,k)
              psmltevp(iq,k)= zzpsmltevp(i,k)
              prain(iq,k)   = zzprain(i,k)
              praut(iq,k)   = zzpraut(i,k)
              pracw(iq,k)   = zzpracw(i,k)
              prevp(iq,k)   = zzprevp(i,k)
              pgfr(iq,k)    = zzpgfr(i,k)
              pvapor(iq,k)  = zzpvapor(i,k)
              pclw(iq,k)    = zzpclw(i,k)
              pladj(iq,k)   = zzpladj(i,k)
              pcli(iq,k)    = zzpcli(i,k)
              pimlt(iq,k)   = zzpimlt(i,k)
              pihom(iq,k)   = zzpihom(i,k)
              pidw(iq,k)    = zzpidw(i,k)
              piadj(iq,k)   = zzpiadj(i,k)
              qschg(iq,k)   = zzqschg(i,k)
            end if
          end do !k loop

          condx(iq) = condx(iq) + real( pptrain + pptsnow + pptice )
          conds(iq) = conds(iq) + real( pptsnow + pptice )
          condg(iq) = 0.0 !condg(iq) + 0. ! for graupel
          precip(iq) = precip(iq) + real( pptrain + pptsnow + pptice )

        end do   !iq loop
      end do     !tile loop
     
      !if ( myid==0 ) then
      !  write(6,*) "Waiting before 2nd LIN barrier"
      !endif
      !call ccmpi_barrier(comm_world)
      !if ( myid==0 ) then
      !  write(6,*) "After 2nd LIN barrier"
      !endif
      
      if ( myid==0 ) then
        write(6,*) "DONE LIN microphysics ",ncloud
      end if 
      if ( any(t_imax < 100. .or. t_imax > 400.)) then
        call ccmpi_abort(-1) 
      end if
    case default
      write(6,*) "ERROR: unknown mp_physics option "
      call ccmpi_abort(-1)
  end select


! Aerosol feedbacks
if ( abs(iaero)>=2 .and. (interp_ncloud(ldr,ncloud)/="LEON".or.cloud_aerosol_mode>0)  ) then
  !$omp do schedule(static) private(is,ie,iq,k,fcol,fr,qtot,xic,xsn,xgr,vave,alph)
  do tile = 1,ntiles
    is = (tile-1)*imax + 1
    ie = tile*imax

    ! fluxi - ice flux leaving layer k to k-1 (kg/m2/s)
    ! fluxs - snow flux leaving layer k to k-1 (kg/m2/s)
    ! fluxg - graupel flux leving layer k to k-1 (kg/m2/s)
    ! fluxr - rain flux leaving layer k to k-1 (kg/m2/s)
    ! fluxm - ice melting flux in layer k (kg/m2/s)
    ! fluxf - liquid freezing flux in layer k (kg/m2/s)

    ! fevap - evaporation of rainfall flux (kg/m2/s)
    ! fsubl - sublimation of snow, ice and graupel flux (kg/m2/s)
    ! fauto - autoconversion flux for rainfall (kg/m2/s)
    ! fcoll - collection of cloud liquid water by rain (kg/m2/s)
    ! faccr - accretion of cloud liquid water by snow, ice and graupel (kg/m2/s)

    ! vi - icefall velocity (m/s)
    ! vs - snowfall velocity (m/s)
    ! vg - graupelfall velocity (m/s)
    if (myid == 0 .and. tile==1 ) then
      print*, 'fluxr :', minval(fluxr(is:ie,:)), maxval(fluxr(is:ie,:))
      print*, 'fluxm :', minval(fluxm(is:ie,:)), maxval(fluxm(is:ie,:))
      print*, 'fluxf :', minval(fluxf(is:ie,:)), maxval(fluxf(is:ie,:))
      print*, 'fluxi :', minval(fluxi(is:ie,:)), maxval(fluxi(is:ie,:))
      print*, 'fluxs :', minval(fluxs(is:ie,:)), maxval(fluxs(is:ie,:))
      print*, 'fluxg :', minval(fluxg(is:ie,:)), maxval(fluxg(is:ie,:))
      print*, 'fevap :', minval(fevap(is:ie,:)), maxval(fevap(is:ie,:))
      print*, 'fsubl :', minval(fsubl(is:ie,:)), maxval(fsubl(is:ie,:))
      print*, 'fauto :', minval(fauto(is:ie,:)), maxval(fauto(is:ie,:))
      print*, 'fcoll :', minval(fcoll(is:ie,:)), maxval(fcoll(is:ie,:))
      print*, 'faccr :', minval(faccr(is:ie,:)), maxval(faccr(is:ie,:))
      print*, 'vi    :', minval(vi(is:ie,:)), maxval(vi(is:ie,:))
      print*, 'vs    :', minval(vs(is:ie,:)), maxval(vs(is:ie,:))
      print*, 'vg    :', minval(vg(is:ie,:)), maxval(vg(is:ie,:))
    end if
    ppfprec(is:ie,1)   = 0. !At TOA
    ppfmelt(is:ie,1)   = 0. !At TOA
    ppfsnow(is:ie,1)   = 0. !At TOA
    pprfreeze(is:ie,1) = 0. !At TOA
    do k = 1,kl-1
      ! rainfall flux (entering from above) (kg/m2/s)
      ppfprec(is:ie,kl+1-k) = fluxr(is:ie,k+1)+fluxm(is:ie,k)-fluxf(is:ie,k)
      ! snowfall flux (entering from above) (kg/m2/s)
      ppfsnow(is:ie,kl+1-k) = fluxi(is:ie,k+1)+fluxs(is:ie,k+1)+fluxg(is:ie,k+1) &
                              -fluxm(is:ie,k)+fluxf(is:ie,k)
      ! snowfall flux melting in layer k (kg/m2/s)
      ppfmelt(is:ie,kl+1-k) = fluxm(is:ie,k)
      ! rainfall flux freezing in layer k (kg/m2/s)
      pprfreeze(is:ie,kl+1-k) = fluxf(is:ie,k)
    end do
    do k = 1,kl
      ! rainall flux evaporating in layer k
      ppfevap(is:ie,kl+1-k) = fevap(is:ie,k)
      ! snowfall flux evaporating in layer k
      ppfsubl(is:ie,kl+1-k) = fsubl(is:ie,k)
      ! precipitation formation rate (kg/kg/s)
      ppmrate(is:ie,kl+1-k) = (fauto(is:ie,k)+fcoll(is:ie,k))/(rhoa(is:ie,k)*dz(is:ie,k))
      ! liquid accertion rate (kg/kg/s)
      ppmaccr(is:ie,kl+1-k) = faccr(is:ie,k)/(rhoa(is:ie,k)*dz(is:ie,k))
      ! slope (lambda) for snow crystal size distribution (m**-1)
      pplambs(is:ie,kl+1-k) = 1.6e3*10**(-0.023*(t(iq,k)-tfrz))
      ! Fraction rain scavenging rate in time-step
      do iq = is,ie
        fcol = rfrac(iq,k)
        Fr = fluxr(iq,k)/max(rfrac(iq,k),1.e-10)
        pprscav(iq,kl+1-k) = dt*0.24*fcol*Fr**0.75
      end do
      ! Fractional ice sedimentation in time-step
      do iq = is,ie
        qtot = max( qfg(iq,k) + qsng(iq,k) + qgrg(iq,k), 1.e-10 )
        xsn = qsng(iq,k)/qtot
        xgr = qgrg(iq,k)/qtot
        xic = 1. - xsn - xgr
        vave = xic*vi(iq,k) + xsn*vs(iq,k) + xgr*vg(iq,k)
        alph = dt*vave/dz(iq,k)
        ppqfsedice(iq,kl+1-k) = 1. - exp(-alph)
      end do
    end do
  end do ! tile
  !$omp end do nowait
end if   ! if abs(iaero)>=2 .and. (interp_ncloud(ldr,ncloud)/="LEON".or.cloud_aerosol_mode>0)


#ifdef COSPP

#ifdef _OPENMP
write(6,*) "ERROR: COSP is current incompatible with OMP"
stop
#endif

!====================================================================================================
! WRITE DATA TO HISTORY AND RESTART FILES ---------------
! Only call COSP if outcdf is called in globpea.f90 to update ouput
!====================================================================================================
if ( ktau==ntau .or. mod(ktau,nwt)==0 ) then 

  Npoints_it      = imax
  Npoints         = imax
  Nptsperit       = imax
  rttov_nChannels = 3
  nLevels         = kl
  nColumns        = 20 
  cloudsat_micro_scheme = 'MMF_v3.5_single_moment'

  !====================================================================================================
  ! ARRAY ALLOCATION CHECKING
  !====================================================================================================
  ! Check allocation for INPUT data
  if ( .not.allocated(mr_lsliq) ) then
  allocate(lon(Npoints),lat(Npoints),p(Npoints,Nlevels),ph(Npoints,Nlevels),             &
           zlev(Npoints,Nlevels),zlev_half(Npoints,Nlevels),Te(Npoints,Nlevels),         &
           qv(Npoints,Nlevels),rh(Npoints,Nlevels),tca(Npoints,Nlevels),                 &
           cca(Npoints,Nlevels),mr_lsliq(Npoints,Nlevels),mr_lsice(Npoints,Nlevels),     &
           mr_ccliq(Npoints,Nlevels),mr_ccice(Npoints,Nlevels),                          &
           fl_lsrain(Npoints,Nlevels),fl_lssnow(Npoints,Nlevels),                        &
           fl_lsgrpl(Npoints,Nlevels),fl_ccrain(Npoints,Nlevels),                        &
           fl_ccsnow(Npoints,Nlevels),Reff(Npoints,Nlevels,N_HYDRO),                     &
           dtau_s(Npoints,Nlevels),dtau_c(Npoints,Nlevels),dem_s(Npoints,Nlevels),       &
           dem_c(Npoints,Nlevels),skt(Npoints),landmask(Npoints),                        &
           mr_ozone(Npoints,Nlevels),u_wind(Npoints),v_wind(Npoints),sunlit(Npoints),    &
           frac_out(Npoints,Ncolumns,Nlevels),surfelev(Npoints))
   allocate(zlev_inv(Npoints,Nlevels),Te_inv(Npoints,Nlevels),qv_inv(Npoints,Nlevels),   &
           p_inv(Npoints,Nlevels),ph_inv(Npoints,Nlevels),zlev_half_inv(Npoints,Nlevels))
   allocate(Reff2(Npoints,Nlevels,N_HYDRO))
   allocate(tca_inv(Npoints,Nlevels),                                                            &
           cca_inv(Npoints,Nlevels),mr_lsliq_inv(Npoints,Nlevels),mr_lsice_inv(Npoints,Nlevels), &
           mr_ccliq_inv(Npoints,Nlevels),mr_ccice_inv(Npoints,Nlevels),                          &
           fl_lsrain_inv(Npoints,Nlevels),fl_lssnow_inv(Npoints,Nlevels),                        &
           fl_lsgrpl_inv(Npoints,Nlevels),fl_ccrain_inv(Npoints,Nlevels),                        &
           fl_ccsnow_inv(Npoints,Nlevels),Reff_inv(Npoints,Nlevels,N_HYDRO),                     &
           dtau_s_inv(Npoints,Nlevels),dtau_c_inv(Npoints,Nlevels),dem_s_inv(Npoints,Nlevels),   &
           dem_c_inv(Npoints,Nlevels)) 
  end if

  ! Check allocation of OUTPUT vars
  if ( .not. allocated(mr_ccice_o) ) then
    allocate( cltcalipso_o(ifull,4) )
    allocate( caso_ice(ifull,4 ) )
    allocate( caso_liq(ifull,4 ) )
    !allocate( cltcalipso_o(ifull) )
    allocate( mr_ccice_o(ifull,kl) )
    allocate( cloudsat_Ze_tot(ifull,kl,Ncolumns) )
  end if

  !====================================================================================================
  ! Second logical level: Logical switch of which simulator we want to turn on 
  !====================================================================================================
  if (Lpctisccp .or. Lclisccp .or. Lboxptopisccp .or.  Lboxtauisccp .or. Ltauisccp .or. &
      Lcltisccp .or. Lmeantbisccp .or. Lmeantbclrisccp .or. Lalbisccp) Lisccp = .true.
  if (LclMISR) Lmisr = .true.
  if (Lcltmodis .or. Lclwmodis .or. Lclimodis .or. Lclhmodis .or. Lclmmodis .or.         &
      Lcllmodis .or. Ltautmodis .or. Ltauwmodis .or. Ltauimodis .or. Ltautlogmodis .or. &
      Ltauwlogmodis .or. Ltauilogmodis .or. Lreffclwmodis .or. Lreffclimodis .or.       &
      Lpctmodis .or. Llwpmodis .or. Liwpmodis .or. Lclmodis) Lmodis = .true.
  if (Lclcalipso2 .or. Lclcalipso .or.  Lclhcalipso .or. Lcllcalipso .or. Lclmcalipso    &
      .or. Lcltcalipso .or. Lcltlidarradar .or. Lclcalipsoliq .or. Lclcalipsoice .or.   &
      Lclcalipsoun .or. Lclcalipsotmp .or. Lclcalipsotmpliq .or. Lclcalipsotmpice .or.  &
      Lclcalipsotmpun .or. Lcltcalipsoliq .or. Lcltcalipsoice .or. Lcltcalipsoun .or.   &
      Lclhcalipsoliq .or. Lclhcalipsoice .or. Lclhcalipsoun .or. Lclmcalipsoliq .or.    &
      Lclmcalipsoice .or. Lclmcalipsoun .or. Lcllcalipsoliq .or. Lcllcalipsoice .or.    &
      Lcllcalipsoun .or. LlidarBetaMol532 .or. LcfadLidarsr532 .or. Lcltlidarradar .or. &
      Lcltlidarradar .or. Lclopaquecalipso .or. Lclthincalipso .or. Lclzopaquecalipso   &
      .or. Lclcalipsoopaque .or. Lclcalipsothin .or. Lclcalipsozopaque .or.             &
      Lclcalipsoopacity .or. Lclopaquetemp .or. Lclthintemp .or. Lclzopaquetemp .or.    &
      Lclopaquemeanz .or. Lclthinmeanz .or. Lclthinemis .or. Lclopaquemeanzse .or.      &
      Lclthinmeanzse .or. Lclzopaquecalipsose) Lcalipso = .true.

  if (LlidarBetaMol532gr .or. LcfadLidarsr532gr .or. Latb532gr .or. LclgrLidar532 .or.  &
      LclhgrLidar532 .or. LcllgrLidar532 .or. LclmgrLidar532 .or. LcltgrLidar532)   &
      LgrLidar532 = .true.

  if (LlidarBetaMol355 .or. LcfadLidarsr355 .or. Latb355 .or. Lclatlid .or.              &
      Lclhatlid .or. Lcllatlid .or. Lclmatlid .or. Lcltatlid)                           &
      Latlid = .true.

  if (LcfadDbze94 .or. Ldbze94 .or. Lcltlidarradar) Lcloudsat = .true.

  if (LcfadDbze94 .or. Ldbze94 .or. Lcltlidarradar .or. Lptradarflag0 .or. Lptradarflag1 &
      .or. Lptradarflag2 .or. Lptradarflag3 .or. Lptradarflag4 .or. Lptradarflag5 .or.  &
      Lptradarflag6 .or. Lptradarflag7 .or. Lptradarflag8 .or. Lptradarflag9 .or.       &
      Lradarpia) Lcloudsat = .true.
  if (Lparasolrefl) Lparasol = .true.
  if (Ltbrttov) Lrttov = .true.
  !====================================================================================================
  !                          FINISH DATA DECLERATION FOR COSP AND CCAM!!!
  !                                  NOW INITIALIZING COSP .........................
  !                     This only needs to be done the first time that COSP is called
  !====================================================================================================
  ! Initialize quickbeam_optics, also if two-moment radar microphysics scheme is wanted...
  if (cloudsat_micro_scheme == 'MMF_v3.5_two_moment')  then
     ldouble = .true.
     lsingle = .false.
  endif

  ! 1st call: initial quickbeam
  call quickbeam_optics_init()

  ! 2nd call: Initialize the distributional parameters for hydrometeors in radar simulator
  call hydro_class_init(lsingle,ldouble,sd)
#ifdef sonny_debug
if (myid==0 ) then
    print*, ' ======='
    print*, 'cosp_calipso_init PRINT OUT THE OUTPUT VALUES IN SD TYPE AFTER hydro_class_init'
    print*, ' ====================================================='
    print*, 'sd%dtype(1:N_HYDRO) ', sd%dtype(1:N_HYDRO)
    print*, 'sd%phase(1:N_HYDRO) ', sd%phase(1:N_HYDRO)
    print*, 'sd%dmin(1:N_HYDRO)  ', sd%dmin(1:N_HYDRO)
    print*, 'sd%dmax(1:N_HYDRO)  ', sd%dmax(1:N_HYDRO)
    print*, 'sd%apm(1:N_HYDRO)   ', sd%apm(1:N_HYDRO)
    print*, 'sd%bpm(1:N_HYDRO)   ', sd%bpm(1:N_HYDRO)
    print*, 'sd%rho(1:N_HYDRO)   ', sd%rho(1:N_HYDRO)
    print*, 'sd%p1(1:N_HYDRO)    ', sd%p1(1:N_HYDRO)
    print*, 'sd%p2(1:N_HYDRO)    ', sd%p2(1:N_HYDRO)
    print*, 'sd%p3(1:N_HYDRO)    ', sd%p3(1:N_HYDRO)
    print*, '======='
    print*, 'PRINT OUT THE INPUT VALUES FOR "COSP_INIT"'
    print*, ' ====================================================='
    print*, 'Lisccp      ',   Lisccp
    print*, 'Lmodis      ',   Lmodis
    print*, 'Lmisr       ',   Lmisr
    print*, 'Lcloudsat   ',   Lcloudsat
    print*, 'Lcalipso    ',   Lcalipso
    print*, 'LgrLidar532 ',   LgrLidar532
    print*, 'Latlid      ',   Latlid
    print*, 'Lparasol    ',   Lparasol
    print*, 'Lrttov      ',   Lrttov

    print*, 'cloudsat_use_gas_abs      :', cloudsat_use_gas_abs
    print*, 'cloudsat_do_ray           :', cloudsat_do_ray
    print*, 'isccp_topheight           :', isccp_topheight
    print*, 'isccp_topheight_direction :', isccp_topheight_direction
    print*, 'Nlevels                   :', Nlevels
    print*, 'Nvgrid                    :', Nlvgrid
    print*, 'surface_radar             :', surface_radar

    print*, 'cloudsat_radar_freq       :', cloudsat_radar_freq
    print*, 'cloudsat_k2               :', cloudsat_k2
    print*, 'lusevgrid                 :', use_vgrid
    print*, 'luseCSATvgrid             :', csat_vgrid
    print*, 'cloudsat_micro_scheme     :', cloudsat_micro_scheme
  end if
#endif
  ! 3rd call: Initialize COSP simulator
  call COSP_INIT(Lisccp, Lmodis, Lmisr, Lcloudsat, Lcalipso, LgrLidar532, Latlid,                  &
                 Lparasol, Lrttov,                                                                 &
                 cloudsat_radar_freq, cloudsat_k2, cloudsat_use_gas_abs,                           &
                 cloudsat_do_ray, isccp_topheight, isccp_topheight_direction, surface_radar,       &
                 rcfg_cloudsat, use_vgrid, csat_vgrid, Nlvgrid, Nlevels, cloudsat_micro_scheme)
  
  !====================================================================================================
  ! 4th call: Construct output derived type.
  ! *NOTE* The "construct/destroy" subroutines are local to this module and should be
  !        modified for your configuration. E.g. it may be overkill to query each field.
  !====================================================================================================
  call construct_cosp_outputs(Lpctisccp, Lclisccp, Lboxptopisccp, Lboxtauisccp,          &
       Ltauisccp, Lcltisccp, Lmeantbisccp, Lmeantbclrisccp, Lalbisccp, LclMISR,          &
       Lcltmodis, Lclwmodis, Lclimodis, Lclhmodis, Lclmmodis, Lcllmodis, Ltautmodis,     &
       Ltauwmodis, Ltauimodis, Ltautlogmodis, Ltauwlogmodis, Ltauilogmodis,              &
       Lreffclwmodis, Lreffclimodis, Lpctmodis, Llwpmodis, Liwpmodis, Lclmodis, Latb532, &
       Latb532gr, Latb355, LlidarBetaMol532, LlidarBetaMol532gr, LlidarBetaMol355,       &
       LcfadLidarsr532, LcfadLidarsr532gr, LcfadLidarsr355, Lclcalipso2,                 &
       Lclcalipso, LclgrLidar532, Lclatlid, Lclhcalipso, Lcllcalipso, Lclmcalipso,       &
       Lcltcalipso, LclhgrLidar532, LcllgrLidar532, LclmgrLidar532, LcltgrLidar532,      &
       Lclhatlid, Lcllatlid, Lclmatlid, Lcltatlid, Lcltlidarradar,  Lcloudsat_tcc,       &
       Lcloudsat_tcc2, Lclcalipsoliq,        &
       Lclcalipsoice, Lclcalipsoun, Lclcalipsotmp, Lclcalipsotmpliq, Lclcalipsotmpice,   &
       Lclcalipsotmpun, Lcltcalipsoliq, Lcltcalipsoice, Lcltcalipsoun, Lclhcalipsoliq,   &
       Lclhcalipsoice, Lclhcalipsoun, Lclmcalipsoliq, Lclmcalipsoice, Lclmcalipsoun,     &
       Lcllcalipsoliq, Lcllcalipsoice, Lcllcalipsoun, Lclopaquecalipso, Lclthincalipso,  &
       Lclzopaquecalipso, Lclcalipsoopaque, Lclcalipsothin, Lclcalipsozopaque,           &
       Lclcalipsoopacity, Lclopaquetemp, Lclthintemp, Lclzopaquetemp, Lclopaquemeanz,    &
       Lclthinmeanz, Lclthinemis, Lclopaquemeanzse, Lclthinmeanzse, Lclzopaquecalipsose, &
       LcfadDbze94, Ldbze94, Lparasolrefl,                                               &
       Ltbrttov, Lptradarflag0,Lptradarflag1,Lptradarflag2,Lptradarflag3,Lptradarflag4,  &
       Lptradarflag5,Lptradarflag6,Lptradarflag7,Lptradarflag8,Lptradarflag9,Lradarpia,  &
       Lwr_occfreq, Lcfodd,                                                              &
       Npoints, Ncolumns, Nlevels,                                                       & !Nlvgrid_local, 
       Nlvgrid_local, rttov_Nchannels, cospOUT)

  !====================================================================================================
  ! BREAK COSP UP INTO NTILES FOR CCAM
  ! It is a 'chunk' in COSP
  ! nChunks = # Points to Process (nPoints) / # Points per COSP iteration (nPoints_it)
  ! #Points to Process (nPoints)  == imax in CCAM
  ! #Points per COSP iteration (nPoints_it) == also imax in CCAM
  !====================================================================================================
  do tile = 1,ntiles
#ifdef sonny_debug  
    if (myid==0 ) then
      print*, 'Number of ntiles    :', ntiles
      print*, 'Now at tile/ntiles  :', tile, '/', ntiles
      print*, '**************************************************************************************'
    end if
#endif
    is = (tile-1)*imax + 1
    ie = tile*imax          

    start_idx = is
    end_idx   = ie
    nPtsPerIt = imax
    emsfc_lw  = 0.99
    lat       = rlatt(is:ie)*180./3.14159265359         ! Latitude                               (deg)
    lon       = rlongg(is:ie)*180./3.14159265359        ! Longitude                              (deg)
    skt       = tss(is:ie)                              ! Surface temperature                    (K)
    surfelev  = zs(is:ie)/grav                          ! Surface Elevation                      (m)
    
    where (land(is:ie))
      landmask          = 1.                            ! Land/Sea mask                          (0-1)
    elsewhere
      landmask          = 0.
    end where
    umag                = max(hypot(u(is:ie,1),v(is:ie,1)),0.001)
    u_wind              = u10(is:ie)*u(is:ie,1) / umag                        ! U-component of wind (m/s)
    v_wind              = u10(is:ie)*v(is:ie,1) / umag                        ! V-component of wind (m/s)

    where(sgdn(is:ie) > 0.)
      sunlit            = 1.                             ! Sunlit flag                            (0-1)
    elsewhere
      sunlit            = 0.                             ! Sunlit flag                            (0-1)
    end where
    
    do k=1,kl
      p(:,k)            = sig(k)*ps(is:ie)               ! Pressure                               (Pa)
      ph(:,k)           = sigmh(k)*ps(is:ie)             ! Pressure at half-levels                (Pa)
    end do
  
    rong = rdry/grav
    do k = 1,kl
      delh(k)           = -rong*dsig(k)/sig(k)           ! sign of delh defined so always +ve
    end do      
    
    zlev(:,1)           = bet(1)*t(is:ie,1)/grav
    zlev_half(:,1)      = t(is:ie,1)*delh(1)
    do k=2,kl
      zlev(:,k)         = zlev(:,k-1) + (bet(k)*t(is:ie,k)+betm(k)*t(is:ie,k-1))/grav
      zlev_half(:,k)    = zlev_half(:,k-1)+ t(is:ie,k)*delh(k)
    end do


    Te                 = t(is:ie,1:kl)                                ! Temperature                      (K)
    qv                 = qg(is:ie,1:kl)/(1. + qg(is:ie,1:kl))         ! Specific humidity                (kg/kg)
    do k = 1,kl
      qsatg(:,k)       = qsat(p(:,k),Te(:,k),imax)     
      rh(:,k)          = (qg(is:ie,k)+qlg(is:ie,k)+qfg(is:ie,k))/qsatg(:,k)                         ! Relative humidity (1)
    end do  
    
    !CALL RANDOM_NUMBER(Reff     )

    tca           = stratcloud(is:ie,1:kl)  ! Total column cloud fraction            (0-1)
    cca           = 0.                      ! Convective cloud fraction (1)
    mr_lsliq      = qlg(is:ie,1:kl)         ! Mass mixing ratio for stratiform cloud liquid (kg/kg)
    mr_lsice      = qfg(is:ie,1:kl)         ! Mass mixing ratio for stratiform cloud ice (kg/kg)
    mr_ccliq      = 0.                      ! Mass mixing ratio for convective cloud liquid (kg/kg)
    mr_ccice      = 0.                      ! Mass mixing ratio for convective cloud ice (kg/kg)
    mr_ozone      = 0.                      ! Mass mixing ratio for ozone (kg/kg)
    fl_lsrain     = 0.                      ! Precipitation flux (rain) for stratiform cloud (kg/m^2/s)
    fl_lssnow     = 0.                      ! Precipitation flux (snow) for stratiform cloud (kg/m^2/s)
    fl_lsgrpl     = 0.                      ! Precipitation flux (groupel) for stratiform cloud (kg/m^2/s)
    fl_ccrain     = 0.                      ! Precipitation flux (rain) for convective cloud (kg/m^2/s)
    fl_ccsnow     = 0.                      ! Precipitation flux (snow) for convective cloud (kg/m^2/s)
    !dtau_s       = 0.                      ! 0.67micron optical depth (stratiform cloud) (1)
    dtau_c        = 0.                      ! 0.67micron optical depth (convective cloud) (1)
    !dem_s         = 0.                     ! 11micron emissivity (stratiform cloud)
    dem_c         = 0.                      ! 11microm emissivity (convective cloud)
    
    do n = 1,ncolumns
      frac_out(:,n,:)  = cfrac(is:ie,1:kl)                     ! Subcolumn cloud cover (0/1)
    end do

    r_cfrac = cfrac(is:ie,1:kl)
    r_qlrad = qlrad(is:ie,1:kl)
    r_qfrad = qfrad(is:ie,1:kl)
    r_cdrop = cdrop(is:ie,1:kl)
    call cloud3(Rdrop,Rice,conl,coni,r_cfrac,r_qlrad,r_qfrad,p,Te,r_cdrop,imax,kl)
   
    its = is
    ite = ie
    kts = 1
    kte = kl
    do iq = its, ite
      i = iq - its + 1 ! i must be smaller than 97
      do k = kts, kte
        Reff(i,k,1) = Rdrop(i,k)/1.E6   ! Large-scale (stratiform) liquid
        Reff(i,k,2) = Rice(i,k)/1.E6    ! Large-scale (stratiform) ice
        Reff(i,k,3) = 0.0               ! Large-scale (stratiform) rain    
        Reff(i,k,4) = 0.0               ! Large-scale (stratiform) snow
        Reff(i,k,5) = 0.0               ! Convective liquid
        Reff(i,k,6) = 0.0               ! Convective ice
        Reff(i,k,7) = 0.0               ! Convective rain
        Reff(i,k,8) = 0.0               ! Convective snow
        Reff(i,k,9) = 0.0               ! Large-scale (stratiform) groupel
      end do
    end do


    do k = 1,kl
      do iq = its, ite
        i = iq -its + 1
        !slwp = -dsig(k)*r_qlrad(i,k)*ps(iq)/grav
        slwp = -dsig(k)*qlrad(iq,k)*ps(iq)/grav !sig(k)
        siwp = -dsig(k)*qfrad(iq,k)*ps(iq)/grav
        sdrop = Rdrop(i,k)
        sice  = Rice(i,k)
        tau_liq(1) = slwp*1000.*(0.02817 + (1.305/sdrop))
        tau_liq(2) = slwp*1000.*(0.02682 + (1.346/sdrop))
        tau_liq(3) = slwp*1000.*(0.02264 + (1.454/sdrop))
        tau_liq(4) = slwp*1000.*(0.01281 + (1.641/sdrop))
        tau_ice    = siwp*1000.*(0.003448 + (2.431/sice))
        !cloud_tau(i,k) = sum(tau_liq,dim=3)/4. + tau_ice ! 4 bands
        cloud_tau(i,k) = (tau_liq(1)+tau_liq(2)+tau_liq(3)+ &
                         tau_liq(4)) / 4 + tau_ice 
        k_liq = 140.
        k_ice = 4.83591 + 1758.511/sice
        cloud_emiss(i,k) = 1. - exp(-(k_liq*slwp + k_ice*siwp))
      end do
    end do
    
    dtau_s = cloud_tau
    dem_s  = cloud_emiss
    if (myid == 0) then
      print*, 'Starting ..............................................'
      print*, 'Rdrop values: ', minval(Reff(:,:,1)), maxval(Reff(:,:,1))
      print*, 'Rdrop values: ', minval(Rdrop) ! 33.20
      print*, 'Rice values : ', minval(Reff(:,:,2)), maxval(Reff(:,:,2))
      print*, 'Rice values : ', maxval(Rice)   ! 100.59
      print*, 'cloud_tau   : ', minval(cloud_tau), maxval(cloud_tau)
      print*, 'cloud_emiss : ', minval(cloud_emiss), maxval(cloud_emiss)
      print*, 'Ending ..............................................'
      print*, ' '
    end if
    seaice        = fracice(is:ie)         ! Sea-ice fraction                       (0-1)

#ifdef COSPP    
    if (myid==0 ) then
      print*, ' ======'
      print*, ' PRINT OUT THE INPUT FOR THE COSP'
      print*, '=================================='
      print*, 'Npoints  : ', Npoints
      print*, 'Nlevels  : ', Nlevels
      print*, 'N_HYDRO  : ', N_HYDRO
      print*, 'lat      : ', minval(lat      ), maxval(lat      ), 'shape:', shape(lat      )
      print*, 'lon      : ', minval(lon      ), maxval(lon      ), 'shape:', shape(lon      )
      print*, 'p        : ', minval(p        ), maxval(p        ), 'shape:', shape(p        )
      print*, 'ph       : ', minval(ph       ), maxval(ph       ), 'shape:', shape(ph       )
      print*, 'zlev     : ', minval(zlev     ), maxval(zlev     ), 'shape:', shape(zlev     )
      print*, 'zlev_half: ', minval(zlev_half), maxval(zlev_half), 'shape:', shape(zlev_half)
      print*, 'Te       : ', minval(Te       ), maxval(Te       ), 'shape:', shape(Te       )
      print*, 'qv       : ', minval(qv       ), maxval(qv       ), 'shape:', shape(qv       )
      print*, 'rh       : ', minval(rh       ), maxval(rh       ), 'shape:', shape(rh       )
      print*, 'tca      : ', minval(tca      ), maxval(tca      ), 'shape:', shape(tca      )
      print*, 'cca      : ', minval(cca      ), maxval(cca      ), 'shape:', shape(cca      )
      print*, 'mr_lsliq : ', minval(mr_lsliq ), maxval(mr_lsliq ), 'shape:', shape(mr_lsliq )
      print*, 'mr_lsice : ', minval(mr_lsice ), maxval(mr_lsice ), 'shape:', shape(mr_lsice )
      print*, 'mr_ccliq : ', minval(mr_ccliq ), maxval(mr_ccliq ), 'shape:', shape(mr_ccliq )
      print*, 'mr_ccice : ', minval(mr_ccice ), maxval(mr_ccice ), 'shape:', shape(mr_ccice )
      print*, 'fl_lsrain: ', minval(fl_lsrain), maxval(fl_lsrain), 'shape:', shape(fl_lsrain)
      print*, 'fl_lssnow: ', minval(fl_lssnow), maxval(fl_lssnow), 'shape:', shape(fl_lssnow)
      print*, 'fl_lsgrpl: ', minval(fl_lsgrpl), maxval(fl_lsgrpl), 'shape:', shape(fl_lsgrpl)
      print*, 'fl_ccrain: ', minval(fl_ccrain), maxval(fl_ccrain), 'shape:', shape(fl_ccrain)
      print*, 'fl_ccsnow: ', minval(fl_ccsnow), maxval(fl_ccsnow), 'shape:', shape(fl_ccsnow)
      print*, 'Reff     : ', minval(Reff     ), maxval(Reff     ), 'shape:', shape(Reff     )
      print*, 'dtau_s   : ', minval(dtau_s   ), maxval(dtau_s   ), 'shape:', shape(dtau_s   )
      print*, 'dtau_c   : ', minval(dtau_c   ), maxval(dtau_c   ), 'shape:', shape(dtau_c   )
      print*, 'dem_s    : ', minval(dem_s    ), maxval(dem_s    ), 'shape:', shape(dem_s    )
      print*, 'dem_c    : ', minval(dem_c    ), maxval(dem_c    ), 'shape:', shape(dem_c    )
      print*, 'skt      : ', minval(skt      ), maxval(skt      ), 'shape:', shape(skt      )
      print*, 'landmask : ', minval(landmask ), maxval(landmask ), 'shape:', shape(landmask )
      print*, 'mr_ozone : ', minval(mr_ozone ), maxval(mr_ozone ), 'shape:', shape(mr_ozone )
      print*, 'u_wind   : ', minval(u_wind   ), maxval(u_wind   ), 'shape:', shape(u_wind   )
      print*, 'v_wind   : ', minval(v_wind   ), maxval(v_wind   ), 'shape:', shape(v_wind   )
      print*, 'sunlit   : ', minval(sunlit   ), maxval(sunlit   ), 'shape:', shape(sunlit   )
      print*, 'emsfc_lw : ', emsfc_lw
      print*, 'geomode  : ', geomode
      print*, 'Nlon     : ', Nlon
      print*, 'Nlat     : ', Nlat
      print*, 'surfelev : ', minval(surfelev ), maxval(surfelev ), 'shape:', shape(surfelev )
    end if
#endif    
    ! Construct COSP input types
    Npoints_it      = imax
    Npoints         = imax
    Nptsperit       = imax
    rttov_nChannels = 3
    nLevels         = kl
    nColumns        = 20
    cloudsat_micro_scheme = 'MMF_v3.5_single_moment'
   
    !if (tile .eq. 1) then
    if ( .not. allocated( cospstateIN%phalf ) ) then
      call construct_cospIN(Nptsperit,nColumns,nLevels,cospIN)
      call construct_cospstateIN(Nptsperit,nLevels,rttov_nChannels,cospstateIN)
    endif

!====================================================================================================
    ! Populate input types with model fields.
    ! Here the 3D sample model fields (temperature,pressure,etc...) are ordered from the
    ! surface-2-TOA, whereas COSP expects all fields to be ordered from TOA-2-SFC. So the
    ! vertical fields are flipped prior to storing to COSP input type.
!====================================================================================================
    do k = 1,Nlevels
      zlev_inv(:,k) = zlev(1:imax,Nlevels-k+1)
      qv_inv(:,k)   = qv(1:imax,Nlevels-k+1)
      Te_inv(:,k)   = Te(1:imax,Nlevels-k+1)
      p_inv(:,k)    = p(1:imax,Nlevels-k+1)
      ph_inv(:,k)   = ph(1:imax,Nlevels-k+1)
      zlev_half_inv(:,k) = zlev_half(1:imax,Nlevels-k+1)
    end do  

    cospIN%emsfc_lw         = emsfc_lw
    cospIN%rcfg_cloudsat    = rcfg_cloudsat
    cospIN%Npoints          = imax
    cospIN%Ncolumns         = 20 
    cospIN%Nlevels          = kl
    cospIN%frac_out         = frac_out
    cospstateIN%Npoints     = imax
    cospstateIN%Nlevels     = kl
    cospstateIN%Ncolumns    = 20
    cospstateIN%hgt_matrix  = zlev_inv                  ! m
    cospstateIN%sunlit      = sunlit(1:imax)            ! 0-1
    cospstateIN%skt         = skt(:)                    ! K
    cospstateIN%surfelev    = surfelev(:)               ! m
    cospstateIN%land        = landmask(:)               ! 0-1 (*note* model specific)
    cospstateIN%qv          = qv_inv                    ! kg/kg
    cospstateIN%at          = Te_inv                    ! K
    cospstateIN%pfull       = p_inv                     ! Pa
    ! Pressure at interface (nlevels+1). Set uppermost interface to 0.
    cospstateIN%phalf(:,2:Nlevels+1) = ph_inv(:,1:Nlevels) !(:,Nlevels:1:-1)   ! Pa
    cospstateIN%phalf(:,1)  = 0._wp
    ! Height of bottom interfaces of model layers (nlevels).
    ! cospstateIN%hgt_matrix_half(:,1) contains the bottom of the top layer.
    ! cospstateIN%hgt_matrix_half(:,Nlevels) contains the bottom of the surface layer.
    cospstateIN%hgt_matrix_half(:,1:Nlevels) = zlev_half_inv !(:,Nlevels:1:-1) ! km

   ! Generate subcolumns and compute optical inputs.
    tca_inv(1:imax,1:Nlevels)        = tca(1:imax,Nlevels:1:-1)
    cca_inv(1:imax,1:Nlevels)        = cca(1:imax,Nlevels:1:-1)
    fl_lsrain_inv(1:imax,1:Nlevels)  = fl_lsrain(1:imax,Nlevels:1:-1)
    fl_lssnow_inv(1:imax,1:Nlevels)  = fl_lssnow(1:imax,Nlevels:1:-1)
    fl_lsgrpl_inv(1:imax,1:Nlevels)  = fl_lsgrpl(1:imax,Nlevels:1:-1)
    fl_ccrain_inv(1:imax,1:Nlevels)  = fl_ccrain(1:imax,Nlevels:1:-1)
    fl_ccsnow_inv(1:imax,1:Nlevels)  = fl_ccsnow(1:imax,Nlevels:1:-1)
    mr_lsliq_inv(1:imax,1:Nlevels)   = mr_lsliq(1:imax,Nlevels:1:-1)
    mr_lsice_inv(1:imax,1:Nlevels)   = mr_lsice(1:imax,Nlevels:1:-1)
    mr_ccliq_inv(1:imax,1:Nlevels)   = mr_ccliq(1:imax,Nlevels:1:-1)
    mr_ccice_inv(1:imax,1:Nlevels)   = mr_ccice(1:imax,Nlevels:1:-1)
    Reff_inv(1:imax,1:Nlevels,:)     = Reff(1:imax,Nlevels:1:-1,:)
    dtau_c_inv(1:imax,1:Nlevels)     = dtau_c(1:imax,Nlevels:1:-1)
    dtau_s_inv(1:imax,1:Nlevels)     = dtau_s(1:imax,Nlevels:1:-1)
    dem_c_inv(1:imax,1:Nlevels)      = dem_c(1:imax,Nlevels:1:-1)
    dem_s_inv(1:imax,1:Nlevels)      = dem_s(1:imax,Nlevels:1:-1)

    call subsample_and_optics(nPtsPerIt,nLevels,nColumns,N_HYDRO,overlap,                              &
                              use_vgrid,use_precipitation_fluxes,lidar_ice_type,sd,                    &
                              tca_inv,cca_inv,fl_lsrain_inv,fl_lssnow_inv,fl_lsgrpl_inv,fl_ccrain_inv, &
                              fl_ccsnow_inv,mr_lsliq_inv,                                              & 
                              mr_lsice_inv,mr_ccliq_inv,mr_ccice_inv,Reff_inv,dtau_c_inv,dtau_s_inv,   &
                              dem_c_inv,dem_s_inv,cospstateIN,cospIN) 

     tca(1:imax,Nlevels:1:-1)        = tca_inv(1:imax,1:Nlevels)
     cca(1:imax,Nlevels:1:-1)        = cca_inv(1:imax,1:Nlevels)
     fl_lsrain(1:imax,Nlevels:1:-1)  = fl_lsrain_inv(1:imax,1:Nlevels)
     fl_lssnow(1:imax,Nlevels:1:-1)  = fl_lssnow_inv(1:imax,1:Nlevels)
     fl_lsgrpl(1:imax,Nlevels:1:-1)  = fl_lsgrpl_inv(1:imax,1:Nlevels)
     fl_ccrain(1:imax,Nlevels:1:-1)  = fl_ccrain_inv(1:imax,1:Nlevels)
     fl_ccsnow(1:imax,Nlevels:1:-1)  = fl_ccsnow_inv(1:imax,1:Nlevels) 
     mr_lsliq(1:imax,Nlevels:1:-1)   = mr_lsliq_inv(1:imax,1:Nlevels)
     mr_lsice(1:imax,Nlevels:1:-1)   = mr_lsice_inv(1:imax,1:Nlevels) 
     mr_ccliq(1:imax,Nlevels:1:-1)   = mr_ccliq_inv(1:imax,1:Nlevels)
     mr_ccice(1:imax,Nlevels:1:-1)   = mr_ccice_inv(1:imax,1:Nlevels)
     Reff(1:imax,Nlevels:1:-1,:)     = Reff_inv(1:imax,1:Nlevels,:)
     dtau_c(1:imax,Nlevels:1:-1)     = dtau_c_inv(1:imax,1:Nlevels)
     dtau_s(1:imax,Nlevels:1:-1)     = dtau_s_inv(1:imax,1:Nlevels) 
     dem_c(1:imax,Nlevels:1:-1)      = dem_c_inv(1:imax,1:Nlevels)
     dem_s(1:imax,Nlevels:1:-1)      = dem_s_inv(1:imax,1:Nlevels)

    !=================================================================================================
    ! Call main COSP function
    !=================================================================================================
    cosp_status = COSP_SIMULATOR(cospIN, cospstateIN, cospOUT,1,imax,.false.)
    do ij=1,size(cosp_status,1)
      if (cosp_status(ij) .ne. '') print*,trim(cosp_status(ij))
    end do
    
    ! writting output
    do n = 1,ncolumns
      cloudsat_Ze_tot(is:ie,1:kl,n) = cospOUT%cloudsat_Ze_tot(:,n,:)
    end do

    !Npoints,  & ! Number of gridpoints
    !Ncolumns, & ! Number of subcolumns
    !Nlevels,  & ! Number of vertical levels
    !Ncat,     & ! Number of cloud layer types
    !Nphase      ! Number of cloud layer phase types
                 ! [ice,liquid,undefined,false ice,false liquid,Percent of ice]

    do n=1,4
      caso_ice(is:ie,n) =  cospOUT%calipso_lidarcldphase(:,n,1)
      caso_liq(is:ie,n) =  cospOUT%calipso_lidarcldphase(:,n,2)
    end do

    cnttt = 0
    do kkk=1,ncolumns
      do jjj=1,kl
        do iii=is,ie
          if (cloudsat_Ze_tot(iii,jjj,kkk) > 0.0) then
             cnttt = cnttt + 1
          end if
        end do
      end do
    end do
    do n=1,4
      cltcalipso_o(is:ie,n) = cospOUT%calipso_cldlayer(:,n)
    end do

    !cltcalipso_o(is:ie) = cospOUT%calipso_cldlayer(:,1)
    mr_ccice_o(is:ie,1:kl)  = mr_ccice(:,:)
    
    
  end do !for each tile  
  print*, '# cloudsat_Ze_tot > 0 : ', cnttt,count(cloudsat_ze_tot>0.)
  print*, 'cloudsat_Ze_tot       : ', minval(cloudsat_Ze_tot), maxval(cloudsat_Ze_tot)

  ! Free up memory
  call destroy_cospstateIN(cospstateIN)
  call destroy_cosp_outputs(cospOUT)
  call destroy_cospIN(cospIN)
  call cosp_cleanUp()
endif
#endif

  RETURN
  end subroutine ctrl_microphysics

 !====================================================================================================
 ! SUBROUTINE interp_ncloud
 !   
 ! subroutine to select the cloud microphysics scheme for CCAM
 !====================================================================================================
  function interp_ncloud(ldr, ncloud) result(mp_physics)

  implicit none

  integer, intent(in) :: ldr
  integer, intent(in) :: ncloud
  character(len=10) :: mp_physics

  mp_physics = "ERROR"

  if ( ldr /= 0 ) then
    select case(ncloud)
      case(0,2,3,4,10,12,13,20,21,22)
        mp_physics = "LEON"
      case(100,110,120)
        mp_physics = "LIN"
      end select
  end if
  end function interp_ncloud

#ifdef COSPP  
  !===================================================================================================
  ! SUBROUTINE construct_cospIN
  !
  !====================================================================================================
  subroutine construct_cospIN(npoints,ncolumns,nlevels,y) 
    !use mod_cosp,  only: cosp_optical_inputs,cosp_init
    ! Inputs
    integer,intent(in) :: &
         npoints,  & ! Number of horizontal gridpoints
         ncolumns, & ! Number of subcolumns
         nlevels     ! Number of vertical levels


    ! Outputs
    type(cosp_optical_inputs),intent(out) :: y

    ! Dimensions
    y%Npoints  = Npoints
    y%Ncolumns = Ncolumns
    y%Nlevels  = Nlevels
    y%Npart    = 4
    y%Nrefl    = PARASOL_NREFL
    allocate(y%frac_out(npoints,       ncolumns,nlevels))
    
    if (Lmodis .or. Lmisr .or. Lisccp) then
       allocate(y%tau_067(npoints,        ncolumns,nlevels),&
                y%emiss_11(npoints,       ncolumns,nlevels))
    endif
    if (Lcalipso) then
       allocate(y%betatot_calipso(npoints,        ncolumns,nlevels),&
                y%betatot_ice_calipso(npoints,    ncolumns,nlevels),&
                y%betatot_liq_calipso(npoints,    ncolumns,nlevels),&
                y%tautot_calipso(npoints,         ncolumns,nlevels),&
                y%tautot_ice_calipso(npoints,     ncolumns,nlevels),&
                y%tautot_liq_calipso(npoints,     ncolumns,nlevels),&
                y%beta_mol_calipso(npoints,                nlevels),&
                y%tau_mol_calipso(npoints,                 nlevels),&
                y%tautot_S_ice(npoints,   ncolumns        ),&
                y%tautot_S_liq(npoints,   ncolumns        ))
    endif

    if (LgrLidar532) then
       allocate(y%beta_mol_grLidar532(npoints,          nlevels),&
                y%betatot_grLidar532(npoints,  ncolumns,nlevels),&
                y%tau_mol_grLidar532(npoints,           nlevels),&
                y%tautot_grLidar532(npoints,   ncolumns,nlevels))
    endif

    if (Latlid) then
       allocate(y%beta_mol_atlid(npoints,             nlevels),&
                y%betatot_atlid(npoints,     ncolumns,nlevels),&
                y%tau_mol_atlid(npoints,              nlevels),&
                y%tautot_atlid(npoints,      ncolumns,nlevels))
    endif

    if (Lcloudsat) then
       allocate(y%z_vol_cloudsat(npoints,  ncolumns,nlevels),&
                y%kr_vol_cloudsat(npoints, ncolumns,nlevels),&
                y%g_vol_cloudsat(npoints,  ncolumns,nlevels),&
                y%fracPrecipIce(npoints,   ncolumns))
    endif
    if (Lmodis) then
       allocate(y%fracLiq(npoints,        ncolumns,nlevels),&
                y%asym(npoints,           ncolumns,nlevels),&
                y%ss_alb(npoints,         ncolumns,nlevels))
    endif
    y%frac_out=0
    y%tau_067=0
    y%emiss_11=0
    y%betatot_calipso=0
    y%betatot_ice_calipso=0
    y%betatot_liq_calipso=0
    y%tautot_calipso=0
    y%tautot_ice_calipso=0
    y%tautot_liq_calipso=0
    y%beta_mol_calipso=0
    y%tau_mol_calipso=0
    y%tautot_S_ice=0
    y%tautot_S_liq=0

    y%beta_mol_grLidar532=0
    y%betatot_grLidar532=0
    y%tau_mol_grLidar532=0
    y%tautot_grLidar532=0

    y%beta_mol_atlid=0
    y%betatot_atlid=0
    y%tau_mol_atlid=0
    y%tautot_atlid=0

    y%z_vol_cloudsat=0
    y%kr_vol_cloudsat=0
    y%g_vol_cloudsat=0
    y%fracPrecipIce=0

    y%fracLiq=0
    y%asym=0
    y%ss_alb=0
  end subroutine construct_cospIN

  !===================================================================================================
  ! SUBROUTINE construct_cospstateIN
  !
  !====================================================================================================
  subroutine construct_cospstateIN(npoints,nlevels,nchan,y)
    !use mod_cosp,            only: cosp_column_inputs
    ! Inputs
    integer,intent(in) :: &
         npoints, & ! Number of horizontal gridpoints
         nlevels, & ! Number of vertical levels
         nchan      ! Number of channels
    ! Outputs
    type(cosp_column_inputs),intent(out) :: y

    allocate(y%sunlit(npoints),y%skt(npoints),y%land(npoints),y%at(npoints,nlevels),     &
             y%pfull(npoints,nlevels),y%phalf(npoints,nlevels+1),y%qv(npoints,nlevels),  &
             y%o3(npoints,nlevels),y%hgt_matrix(npoints,nlevels),y%u_sfc(npoints),       &
             y%v_sfc(npoints),y%lat(npoints),y%lon(nPoints),y%emis_sfc(nchan),           &
             y%cloudIce(nPoints,nLevels),y%cloudLiq(nPoints,nLevels),y%surfelev(npoints),&
             y%fl_snow(nPoints,nLevels),y%fl_rain(nPoints,nLevels),y%seaice(npoints),    &
             y%tca(nPoints,nLevels),y%hgt_matrix_half(npoints,nlevels))
    y%sunlit=0.0
    y%skt=0.0
    y%land=0.0
    y%at=0.0
    y%pfull=0.0
    y%phalf=0.0
    y%qv =0.0
    y%o3=0.0
    y%hgt_matrix=0.0
    y%u_sfc=0.0
    y%v_sfc=0.0
    y%lat=0.0
    y%lon=0.0
    y%emis_sfc=0.0
    y%cloudIce=0.0
    y%cloudLiq=0.0
    y%surfelev=0.0
    y%fl_snow=0.0
    y%fl_rain=0.0
    y%seaice=0.0
    y%tca=0.0
    y%hgt_matrix_half=0.0
  end subroutine construct_cospstateIN

  !====================================================================================================
  ! SUBROUTINE construct_cosp_outputs
  !
  ! This subroutine allocates output fields based on input logical flag switches.
  !====================================================================================================
  subroutine construct_cosp_outputs(Lpctisccp,Lclisccp,&
                                    Lboxptopisccp,Lboxtauisccp,Ltauisccp,Lcltisccp,      &
                                    Lmeantbisccp,Lmeantbclrisccp,Lalbisccp,LclMISR,      &
                                    Lcltmodis,Lclwmodis,Lclimodis,Lclhmodis,Lclmmodis,   &
                                    Lcllmodis,Ltautmodis,Ltauwmodis,Ltauimodis,          &
                                    Ltautlogmodis,Ltauwlogmodis,Ltauilogmodis,           &
                                    Lreffclwmodis,Lreffclimodis,Lpctmodis,Llwpmodis,     &
                                    Liwpmodis,Lclmodis,Latb532,Latb532gr,Latb355,        &
                                    LlidarBetaMol532,LlidarBetaMol532gr,LlidarBetaMol355,&
                                    LcfadLidarsr532,LcfadLidarsr532gr,LcfadLidarsr355,   &
                                    Lclcalipso2,Lclcalipso,LclgrLidar532,Lclatlid,      &
                                    Lclhcalipso,Lcllcalipso,Lclmcalipso,Lcltcalipso,     &
                                    LclhgrLidar532,LcllgrLidar532,LclmgrLidar532,     &
                                    LcltgrLidar532,Lclhatlid,Lcllatlid,Lclmatlid,       &
                                    Lcltatlid,Lcltlidarradar,Lcloudsat_tcc,            &
                                    Lcloudsat_tcc2,Lclcalipsoliq,              &
                                    Lclcalipsoice,Lclcalipsoun,Lclcalipsotmp,            &
                                    Lclcalipsotmpliq,Lclcalipsotmpice,Lclcalipsotmpun,   &
                                    Lcltcalipsoliq,Lcltcalipsoice,Lcltcalipsoun,         &
                                    Lclhcalipsoliq,Lclhcalipsoice,Lclhcalipsoun,         &
                                    Lclmcalipsoliq,Lclmcalipsoice,Lclmcalipsoun,         &
                                    Lcllcalipsoliq,Lcllcalipsoice,Lcllcalipsoun,         &
                                    Lclopaquecalipso,Lclthincalipso,Lclzopaquecalipso,   &
                                    Lclcalipsoopaque,Lclcalipsothin,Lclcalipsozopaque,   &
                                    Lclcalipsoopacity,Lclopaquetemp,Lclthintemp,         &
                                    Lclzopaquetemp,Lclopaquemeanz,Lclthinmeanz,          &
                                    Lclthinemis,Lclopaquemeanzse,Lclthinmeanzse,         &
                                    Lclzopaquecalipsose,LcfadDbze94,Ldbze94,Lparasolrefl,&
                                    Ltbrttov, Lptradarflag0,Lptradarflag1,Lptradarflag2, &
                                    Lptradarflag3,Lptradarflag4,Lptradarflag5,           &
                                    Lptradarflag6,Lptradarflag7,Lptradarflag8,           &
                                    Lptradarflag9,Lradarpia,Lwr_occfreq,Lcfodd,          &
                                    Npoints,Ncolumns,Nlevels,Nlvgrid,Nchan,x)
     ! Inputs
     logical,intent(in) :: &
         Lpctisccp,        & ! ISCCP mean cloud top pressure
         Lclisccp,         & ! ISCCP cloud area fraction
         Lboxptopisccp,    & ! ISCCP CTP in each column
         Lboxtauisccp,     & ! ISCCP optical epth in each column
         Ltauisccp,        & ! ISCCP mean optical depth
         Lcltisccp,        & ! ISCCP total cloud fraction
         Lmeantbisccp,     & ! ISCCP mean all-sky 10.5micron brightness temperature
         Lmeantbclrisccp,  & ! ISCCP mean clear-sky 10.5micron brightness temperature
         Lalbisccp,        & ! ISCCP mean cloud albedo
         LclMISR,          & ! MISR cloud fraction
         Lcltmodis,        & ! MODIS total cloud fraction
         Lclwmodis,        & ! MODIS liquid cloud fraction
         Lclimodis,        & ! MODIS ice cloud fraction
         Lclhmodis,        & ! MODIS high-level cloud fraction
         Lclmmodis,        & ! MODIS mid-level cloud fraction
         Lcllmodis,        & ! MODIS low-level cloud fraction
         Ltautmodis,       & ! MODIS total cloud optical thicknes
         Ltauwmodis,       & ! MODIS liquid optical thickness
         Ltauimodis,       & ! MODIS ice optical thickness
         Ltautlogmodis,    & ! MODIS total cloud optical thickness (log10 mean)
         Ltauwlogmodis,    & ! MODIS liquid optical thickness (log10 mean)
         Ltauilogmodis,    & ! MODIS ice optical thickness (log10 mean)
         Lreffclwmodis,    & ! MODIS liquid cloud particle size
         Lreffclimodis,    & ! MODIS ice particle size
         Lpctmodis,        & ! MODIS cloud top pressure
         Llwpmodis,        & ! MODIS cloud liquid water path
         Liwpmodis,        & ! MODIS cloud ice water path
         Lclmodis,         & ! MODIS cloud area fraction
         Latb532,          & ! CALIPSO attenuated total backscatter (532nm)
         Latb532gr,        & ! GROUND LIDAR @ 532NM attenuated total backscatter (532nm)
         Latb355,          & ! ATLID attenuated total backscatter (355nm)
         LlidarBetaMol532, & ! CALIPSO molecular backscatter (532nm)
         LlidarBetaMol532gr,&! GROUND LIDAR @ 532NM molecular backscatter (532nm)
         LlidarBetaMol355, & ! ATLID molecular backscatter (355nm)
         LcfadLidarsr532,  & ! CALIPSO scattering ratio CFAD
         LcfadLidarsr532gr,& ! GROUND LIDAR @ 532NM scattering ratio CFAD
         LcfadLidarsr355,  & ! ATLID scattering ratio CFAD
         Lclcalipso2,      & ! CALIPSO cloud fraction undetected by cloudsat
         Lclcalipso,       & ! CALIPSO cloud area fraction
         LclgrLidar532,   & ! GROUND LIDAR @ 532NM cloud area fraction
         Lclatlid,         & ! ATLID cloud area fraction
         Lclhcalipso,      & ! CALIPSO high-level cloud fraction
         Lcllcalipso,      & ! CALIPSO low-level cloud fraction
         Lclmcalipso,      & ! CALIPSO mid-level cloud fraction
         Lcltcalipso,      & ! CALIPSO total cloud fraction
         LclhgrLidar532,  & ! GROUND LIDAR @ 532NM high-level cloud fraction
         LcllgrLidar532,  & ! GROUND LIDAR @ 532NM low-level cloud fraction
         LclmgrLidar532,  & ! GROUND LIDAR @ 532NM mid-level cloud fraction
         LcltgrLidar532,  & ! GROUND LIDAR @ 532NM total cloud fraction
         Lclhatlid,        & ! ATLID high-level cloud fraction
         Lcllatlid,        & ! ATLID low-level cloud fraction
         Lclmatlid,        & ! ATLID mid-level cloud fraction
         Lcltatlid,        & ! ATLID total cloud fraction
         Lcltlidarradar,   & ! CALIPSO-CLOUDSAT total cloud fraction
         Lcloudsat_tcc,    & !
         Lcloudsat_tcc2,   & !
         Lclcalipsoliq,    & ! CALIPSO liquid cloud area fraction
         Lclcalipsoice,    & ! CALIPSO ice cloud area fraction
         Lclcalipsoun,     & ! CALIPSO undetected cloud area fraction
         Lclcalipsotmp,    & ! CALIPSO undetected cloud area fraction
         Lclcalipsotmpliq, & ! CALIPSO liquid cloud area fraction
         Lclcalipsotmpice, & ! CALIPSO ice cloud area fraction
         Lclcalipsotmpun,  & ! CALIPSO undetected cloud area fraction
         Lcltcalipsoliq,   & ! CALIPSO liquid total cloud fraction
         Lcltcalipsoice,   & ! CALIPSO ice total cloud fraction
         Lcltcalipsoun,    & ! CALIPSO undetected total cloud fraction
         Lclhcalipsoliq,   & ! CALIPSO high-level liquid cloud fraction
         Lclhcalipsoice,   & ! CALIPSO high-level ice cloud fraction
         Lclhcalipsoun,    & ! CALIPSO high-level undetected cloud fraction
         Lclmcalipsoliq,   & ! CALIPSO mid-level liquid cloud fraction
         Lclmcalipsoice,   & ! CALIPSO mid-level ice cloud fraction
         Lclmcalipsoun,    & ! CALIPSO mid-level undetected cloud fraction
         Lcllcalipsoliq,   & ! CALIPSO low-level liquid cloud fraction
         Lcllcalipsoice,   & ! CALIPSO low-level ice cloud fraction
         Lcllcalipsoun,    & ! CALIPSO low-level undetected cloud fraction
         Lclopaquecalipso, & ! CALIPSO opaque cloud cover (2D Map)
         Lclthincalipso,   & ! CALIPSO thin cloud cover (2D Map)
         Lclzopaquecalipso,& ! CALIPSO z_opaque altitude (opaque clouds only, 2D Map)
         Lclcalipsoopaque, & ! CALIPSO opaque cloud profiles 3D fraction
         Lclcalipsothin,   & ! CALIPSO thin cloud profiles 3D fraction
         Lclcalipsozopaque,& ! CALIPSO z_opaque 3D fraction
         Lclcalipsoopacity,& ! CALIPSO opacity 3D fraction
         Lclopaquetemp,    & ! CALIPSO opaque cloud temperature
         Lclthintemp,      & ! CALIPSO thin cloud temperature
         Lclzopaquetemp,   & ! CALIPSO z_opaque temperature
         Lclopaquemeanz,   & ! CALIPSO opaque cloud altitude
         Lclthinmeanz,     & ! CALIPSO thin cloud altitude
         Lclthinemis,      & ! CALIPSO thin cloud emissivity
         Lclopaquemeanzse,   & ! CALIPSO opaque cloud altitude with respect to SE
         Lclthinmeanzse,     & ! CALIPSO thin cloud altitude with respect to SE
         Lclzopaquecalipsose,& ! CALIPSO z_opaque altitude with respect to SE
         LcfadDbze94,      & ! CLOUDSAT radar reflectivity CFAD
         Ldbze94,          & ! CLOUDSAT radar reflectivity
         LparasolRefl,     & ! PARASOL reflectance
         Ltbrttov,         & ! RTTOV mean clear-sky brightness temperature
         Lptradarflag0,    & ! CLOUDSAT
         Lptradarflag1,    & ! CLOUDSAT
         Lptradarflag2,    & ! CLOUDSAT
         Lptradarflag3,    & ! CLOUDSAT
         Lptradarflag4,    & ! CLOUDSAT
         Lptradarflag5,    & ! CLOUDSAT
         Lptradarflag6,    & ! CLOUDSAT
         Lptradarflag7,    & ! CLOUDSAT
         Lptradarflag8,    & ! CLOUDSAT
         Lptradarflag9,    & ! CLOUDSAT
         Lradarpia,        & ! CLOUDSAT
         Lwr_occfreq,      & ! CloudSat+MODIS joint diagnostics
         Lcfodd              ! CloudSat+MODIS joint diagnostics

     integer,intent(in) :: &
          Npoints,         & ! Number of sampled points
          Ncolumns,        & ! Number of subgrid columns
          Nlevels,         & ! Number of model levels
          Nlvgrid,         & ! Number of levels in L3 stats computation
          Nchan              ! Number of RTTOV channels

     ! Outputs
     type(cosp_outputs),intent(out) :: &
          x           ! COSP output structure

     ! ISCCP simulator outputs
    if (Lboxtauisccp)    allocate(x%isccp_boxtau(Npoints,Ncolumns))
    if (Lboxptopisccp)   allocate(x%isccp_boxptop(Npoints,Ncolumns))
    if (Lclisccp)        allocate(x%isccp_fq(Npoints,numISCCPTauBins,numISCCPPresBins))
    if (Lcltisccp)       allocate(x%isccp_totalcldarea(Npoints))
    if (Lpctisccp)       allocate(x%isccp_meanptop(Npoints))
    if (Ltauisccp)       allocate(x%isccp_meantaucld(Npoints))
    if (Lmeantbisccp)    allocate(x%isccp_meantb(Npoints))
    if (Lmeantbclrisccp) allocate(x%isccp_meantbclr(Npoints))
    if (Lalbisccp)       allocate(x%isccp_meanalbedocld(Npoints))

    ! MISR simulator
    if (LclMISR) then
       allocate(x%misr_fq(Npoints,numMISRTauBins,numMISRHgtBins))
       ! *NOTE* These 3 fields are not output, but were part of the v1.4.0 cosp_misr, so
       !        they are still computed. Should probably have a logical to control these
       !        outputs.
       allocate(x%misr_dist_model_layertops(Npoints,numMISRHgtBins))
       allocate(x%misr_meanztop(Npoints))
       allocate(x%misr_cldarea(Npoints))
    endif

    ! MODIS simulator
    if (Lcltmodis)     allocate(x%modis_Cloud_Fraction_Total_Mean(Npoints))
    if (Lclwmodis)     allocate(x%modis_Cloud_Fraction_Water_Mean(Npoints))
    if (Lclimodis)     allocate(x%modis_Cloud_Fraction_Ice_Mean(Npoints))
    if (Lclhmodis)     allocate(x%modis_Cloud_Fraction_High_Mean(Npoints))
    if (Lclmmodis)     allocate(x%modis_Cloud_Fraction_Mid_Mean(Npoints))
    if (Lcllmodis)     allocate(x%modis_Cloud_Fraction_Low_Mean(Npoints))
    if (Ltautmodis)    allocate(x%modis_Optical_Thickness_Total_Mean(Npoints))
    if (Ltauwmodis)    allocate(x%modis_Optical_Thickness_Water_Mean(Npoints))
    if (Ltauimodis)    allocate(x%modis_Optical_Thickness_Ice_Mean(Npoints))
    if (Ltautlogmodis) allocate(x%modis_Optical_Thickness_Total_LogMean(Npoints))
    if (Ltauwlogmodis) allocate(x%modis_Optical_Thickness_Water_LogMean(Npoints))
    if (Ltauilogmodis) allocate(x%modis_Optical_Thickness_Ice_LogMean(Npoints))
    if (Lreffclwmodis) allocate(x%modis_Cloud_Particle_Size_Water_Mean(Npoints))
    if (Lreffclimodis) allocate(x%modis_Cloud_Particle_Size_Ice_Mean(Npoints))
    if (Lpctmodis)     allocate(x%modis_Cloud_Top_Pressure_Total_Mean(Npoints))
    if (Llwpmodis)     allocate(x%modis_Liquid_Water_Path_Mean(Npoints))
    if (Liwpmodis)     allocate(x%modis_Ice_Water_Path_Mean(Npoints))
    if (Lclmodis) then
        allocate(x%modis_Optical_Thickness_vs_Cloud_Top_Pressure(nPoints,numModisTauBins,numMODISPresBins))
        allocate(x%modis_Optical_thickness_vs_ReffLIQ(nPoints,numMODISTauBins,numMODISReffLiqBins))
        allocate(x%modis_Optical_Thickness_vs_ReffICE(nPoints,numMODISTauBins,numMODISReffIceBins))
    endif

    ! LIDAR simulator
    if (LlidarBetaMol532) allocate(x%calipso_beta_mol(Npoints,Nlevels))
    if (Latb532)          allocate(x%calipso_beta_tot(Npoints,Ncolumns,Nlevels))
    if (LcfadLidarsr532)  then
        allocate(x%calipso_srbval(SR_BINS+1))
        allocate(x%calipso_cfad_sr(Npoints,SR_BINS,Nlvgrid))
        allocate(x%calipso_betaperp_tot(Npoints,Ncolumns,Nlevels))
    endif
    if (Lclcalipso)       allocate(x%calipso_lidarcld(Npoints,Nlvgrid))
    if (Lclhcalipso .or. Lclmcalipso .or. Lcllcalipso .or. Lcltcalipso) then
        allocate(x%calipso_cldlayer(Npoints,LIDAR_NCAT))
    endif
    if (Lclcalipsoice .or. Lclcalipsoliq .or. Lclcalipsoun) then
        allocate(x%calipso_lidarcldphase(Npoints,Nlvgrid,6))
    endif
    if (Lclcalipsotmp .or. Lclcalipsotmpliq .or. Lclcalipsoice .or. Lclcalipsotmpun .or. Lclcalipsotmpice) then
        allocate(x%calipso_lidarcldtmp(Npoints,LIDAR_NTEMP,5))
    endif
    if (Lcllcalipsoice .or. Lclmcalipsoice .or. Lclhcalipsoice .or.                   &
        Lcltcalipsoice .or. Lcllcalipsoliq .or. Lclmcalipsoliq .or.                   &
        Lclhcalipsoliq .or. Lcltcalipsoliq .or. Lcllcalipsoun  .or.                   &
        Lclmcalipsoun  .or. Lclhcalipsoun  .or. Lcltcalipsoun) then
        allocate(x%calipso_cldlayerphase(Npoints,LIDAR_NCAT,6))
    endif
    if (Lclopaquecalipso .or. Lclthincalipso .or. Lclzopaquecalipso) then
        allocate(x%calipso_cldtype(Npoints,LIDAR_NTYPE))
    endif
    if (Lclopaquetemp .or. Lclthintemp .or. Lclzopaquetemp) then
        allocate(x%calipso_cldtypetemp(Npoints,LIDAR_NTYPE))
    endif
    if (Lclopaquemeanz .or. Lclthinmeanz) then
        allocate(x%calipso_cldtypemeanz(Npoints,2))
    endif
    if (Lclopaquemeanzse .or. Lclthinmeanzse .or. Lclzopaquecalipsose) then
        allocate(x%calipso_cldtypemeanzse(Npoints,3))
    endif
    if (Lclthinemis) then
        allocate(x%calipso_cldthinemis(Npoints))
    endif
    if (Lclcalipsoopaque .or. Lclcalipsothin .or. Lclcalipsozopaque .or. Lclcalipsoopacity) then
        allocate(x%calipso_lidarcldtype(Npoints,Nlvgrid,LIDAR_NTYPE+1))
    endif
    ! These 2 outputs are part of the calipso output type, but are not controlled by an
    ! logical switch in the output namelist, so if all other fields are on, then allocate
    if (LlidarBetaMol532 .or. Latb532        .or. LcfadLidarsr532 .or. Lclcalipso  .or.  &
        Lclcalipsoice    .or. Lclcalipsoliq  .or. Lclcalipsoun    .or. Lclcalipso2 .or.  &
        Lclhcalipso      .or. Lclmcalipso    .or. Lcllcalipso     .or. Lcltcalipso .or.  &
        Lclcalipsotmp    .or. Lclcalipsoice  .or. Lclcalipsotmpun .or.                   &
        Lclcalipsotmpliq .or. Lcllcalipsoice .or. Lclmcalipsoice  .or.                   &
        Lclhcalipsoice   .or. Lcltcalipsoice .or. Lcllcalipsoliq  .or.                   &
        Lclmcalipsoliq   .or. Lclhcalipsoliq .or. Lcltcalipsoliq  .or.                   &
        Lcllcalipsoun    .or. Lclmcalipsoun  .or. Lclhcalipsoun   .or. Lcltcalipsoun) then
       allocate(x%calipso_tau_tot(Npoints,Ncolumns,Nlevels))
       allocate(x%calipso_temp_tot(Npoints,Nlevels))
    endif

    ! GROUND LIDAR @ 532NM simulator
    if (LlidarBetaMol532gr) allocate(x%grLidar532_beta_mol(Npoints,Nlevels))
    if (Latb532gr)          allocate(x%grLidar532_beta_tot(Npoints,Ncolumns,Nlevels))
    if (LcfadLidarsr532gr) then
        allocate(x%grLidar532_srbval(SR_BINS+1))
        allocate(x%grLidar532_cfad_sr(Npoints,SR_BINS,Nlvgrid))
    endif
    if (LclgrLidar532)     allocate(x%grLidar532_lidarcld(Npoints,Nlvgrid))
    if (LclhgrLidar532 .or. LclmgrLidar532 .or. LcllgrLidar532 .or. LcltgrLidar532) then
        allocate(x%grLidar532_cldlayer(Npoints,LIDAR_NCAT))
    endif

    ! ATLID simulator
    if (LlidarBetaMol355) allocate(x%atlid_beta_mol(Npoints,Nlevels))
    if (Latb355)          allocate(x%atlid_beta_tot(Npoints,Ncolumns,Nlevels))
    if (LcfadLidarsr355) then
        allocate(x%atlid_srbval(SR_BINS+1))
        allocate(x%atlid_cfad_sr(Npoints,SR_BINS,Nlvgrid))
    endif
    if (Lclatlid)     allocate(x%atlid_lidarcld(Npoints,Nlvgrid))
    if (Lclhatlid .or. Lclmatlid .or. Lcllatlid .or. Lcltatlid) then
        allocate(x%atlid_cldlayer(Npoints,LIDAR_NCAT))
    endif

    ! PARASOL
    if (Lparasolrefl) then
        allocate(x%parasolPix_refl(Npoints,Ncolumns,PARASOL_NREFL))
        allocate(x%parasolGrid_refl(Npoints,PARASOL_NREFL))
    endif

    ! Cloudsat simulator
    if (Ldbze94)        allocate(x%cloudsat_Ze_tot(Npoints,Ncolumns,Nlevels))
    if (LcfadDbze94)    allocate(x%cloudsat_cfad_ze(Npoints,cloudsat_DBZE_BINS,Nlvgrid))
    if (Lptradarflag0 .or. Lptradarflag1 .or. Lptradarflag2 .or. Lptradarflag3 .or. &
        Lptradarflag4 .or. Lptradarflag5 .or. Lptradarflag6 .or. Lptradarflag7 .or. &
        Lptradarflag8 .or. Lptradarflag9) then
       allocate(x%cloudsat_precip_cover(Npoints,cloudsat_DBZE_BINS))
    endif
    if (Lradarpia) allocate(x%cloudsat_pia(Npoints))

    ! Combined CALIPSO/CLOUDSAT fields
    if (Lclcalipso2)    allocate(x%lidar_only_freq_cloud(Npoints,Nlvgrid))
    if (Lcltlidarradar) allocate(x%radar_lidar_tcc(Npoints))
    if (Lcloudsat_tcc) allocate(x%cloudsat_tcc(Npoints))
    if (Lcloudsat_tcc2) allocate(x%cloudsat_tcc2(Npoints))

    ! RTTOV
    if (Ltbrttov) allocate(x%rttov_tbs(Npoints,Nchan))

    ! Joint MODIS/CloudSat Statistics
    if (Lwr_occfreq)  allocate(x%wr_occfreq_ntotal(Npoints,WR_NREGIME))
    if (Lcfodd)       allocate(x%cfodd_ntotal(Npoints,CFODD_NDBZE,CFODD_NICOD,CFODD_NCLASS))

  end subroutine construct_cosp_outputs

  !====================================================================================================
  ! SUBROUTINE destroy_cospIN
  !
  ! This subroutine allocates output fields based on input logical flag switches.
  !====================================================================================================
  subroutine destroy_cospIN(y)
   !use mod_cosp,            only: cosp_optical_inputs

    type(cosp_optical_inputs),intent(inout) :: y
    if (allocated(y%tau_067))             deallocate(y%tau_067)
    if (allocated(y%emiss_11))            deallocate(y%emiss_11)
    if (allocated(y%frac_out))            deallocate(y%frac_out)
    if (allocated(y%beta_mol_calipso))    deallocate(y%beta_mol_calipso)
    if (allocated(y%tau_mol_calipso))     deallocate(y%tau_mol_calipso)
    if (allocated(y%betatot_calipso))     deallocate(y%betatot_calipso)
    if (allocated(y%betatot_ice_calipso)) deallocate(y%betatot_ice_calipso)
    if (allocated(y%betatot_liq_calipso)) deallocate(y%betatot_liq_calipso)
    if (allocated(y%tautot_calipso))      deallocate(y%tautot_calipso)
    if (allocated(y%tautot_ice_calipso))  deallocate(y%tautot_ice_calipso)
    if (allocated(y%tautot_liq_calipso))  deallocate(y%tautot_liq_calipso)
    if (allocated(y%tautot_S_liq))        deallocate(y%tautot_S_liq)
    if (allocated(y%tautot_S_ice))        deallocate(y%tautot_S_ice)
    if (allocated(y%z_vol_cloudsat))      deallocate(y%z_vol_cloudsat)
    if (allocated(y%kr_vol_cloudsat))     deallocate(y%kr_vol_cloudsat)
    if (allocated(y%g_vol_cloudsat))      deallocate(y%g_vol_cloudsat)
    if (allocated(y%asym))                deallocate(y%asym)
    if (allocated(y%ss_alb))              deallocate(y%ss_alb)
    if (allocated(y%fracLiq))             deallocate(y%fracLiq)
    if (allocated(y%beta_mol_grLidar532)) deallocate(y%beta_mol_grLidar532)
    if (allocated(y%betatot_grLidar532))  deallocate(y%betatot_grLidar532)
    if (allocated(y%tau_mol_grLidar532))  deallocate(y%tau_mol_grLidar532)
    if (allocated(y%tautot_grLidar532))   deallocate(y%tautot_grLidar532)
    if (allocated(y%beta_mol_atlid))      deallocate(y%beta_mol_atlid)
    if (allocated(y%betatot_atlid))       deallocate(y%betatot_atlid)
    if (allocated(y%tau_mol_atlid))       deallocate(y%tau_mol_atlid)
    if (allocated(y%tautot_atlid))        deallocate(y%tautot_atlid)
    if (allocated(y%fracPrecipIce))      deallocate(y%fracPrecipIce)
  end subroutine destroy_cospIN

  !====================================================================================================
  ! SUBROUTINE destroy_cospstateIN
  !
  !
  !====================================================================================================
   subroutine destroy_cospstateIN(y)
    !use mod_cosp,            only: cosp_column_inputs

    type(cosp_column_inputs),intent(inout) :: y

    if (allocated(y%sunlit))          deallocate(y%sunlit)
    if (allocated(y%skt))             deallocate(y%skt)
    if (allocated(y%land))            deallocate(y%land)
    if (allocated(y%at))              deallocate(y%at)
    if (allocated(y%pfull))           deallocate(y%pfull)
    if (allocated(y%phalf))           deallocate(y%phalf)
    if (allocated(y%qv))              deallocate(y%qv)
    if (allocated(y%o3))              deallocate(y%o3)
    if (allocated(y%hgt_matrix))      deallocate(y%hgt_matrix)
    if (allocated(y%u_sfc))           deallocate(y%u_sfc)
    if (allocated(y%v_sfc))           deallocate(y%v_sfc)
    if (allocated(y%lat))             deallocate(y%lat)
    if (allocated(y%lon))             deallocate(y%lon)
    if (allocated(y%emis_sfc))        deallocate(y%emis_sfc)
    if (allocated(y%cloudIce))        deallocate(y%cloudIce)
    if (allocated(y%cloudLiq))        deallocate(y%cloudLiq)
    if (allocated(y%seaice))          deallocate(y%seaice)
    if (allocated(y%fl_rain))         deallocate(y%fl_rain)
    if (allocated(y%fl_snow))         deallocate(y%fl_snow)
    if (allocated(y%tca))             deallocate(y%tca)
    if (allocated(y%hgt_matrix_half)) deallocate(y%hgt_matrix_half)
    if (allocated(y%surfelev))        deallocate(y%surfelev)

  end subroutine destroy_cospstateIN

  !====================================================================================================
  ! SUBROUTINE destroy_cosp_outputs
  !
  !
  !====================================================================================================
  subroutine destroy_cosp_outputs(y)
     type(cosp_outputs),intent(inout) :: y

     ! Deallocate and nullify
     if (associated(y%calipso_beta_mol))          then
        deallocate(y%calipso_beta_mol)
        nullify(y%calipso_beta_mol)
     endif
     if (associated(y%calipso_temp_tot))          then
        deallocate(y%calipso_temp_tot)
        nullify(y%calipso_temp_tot)
     endif
     if (associated(y%calipso_betaperp_tot))      then
        deallocate(y%calipso_betaperp_tot)
        nullify(y%calipso_betaperp_tot)
     endif
     if (associated(y%calipso_beta_tot))          then
        deallocate(y%calipso_beta_tot)
        nullify(y%calipso_beta_tot)
     endif
     if (associated(y%calipso_tau_tot))           then
        deallocate(y%calipso_tau_tot)
        nullify(y%calipso_tau_tot)
     endif
     if (associated(y%calipso_lidarcldphase))     then
        deallocate(y%calipso_lidarcldphase)
        nullify(y%calipso_lidarcldphase)
     endif
     if (associated(y%calipso_lidarcldtype))     then
        deallocate(y%calipso_lidarcldtype)
        nullify(y%calipso_lidarcldtype)
     endif
     if (associated(y%calipso_cldlayerphase))     then
        deallocate(y%calipso_cldlayerphase)
        nullify(y%calipso_cldlayerphase)
     endif
     if (associated(y%calipso_lidarcldtmp))       then
        deallocate(y%calipso_lidarcldtmp)
        nullify(y%calipso_lidarcldtmp)
     endif
     if (associated(y%calipso_cldlayer))          then
        deallocate(y%calipso_cldlayer)
        nullify(y%calipso_cldlayer)
     endif
     if (associated(y%calipso_cldtype))          then
        deallocate(y%calipso_cldtype)
        nullify(y%calipso_cldtype)
     endif
     if (associated(y%calipso_cldtypetemp))      then
        deallocate(y%calipso_cldtypetemp)
        nullify(y%calipso_cldtypetemp)
     endif
     if (associated(y%calipso_cldtypemeanz))     then
        deallocate(y%calipso_cldtypemeanz)
        nullify(y%calipso_cldtypemeanz)
     endif
     if (associated(y%calipso_cldtypemeanzse))   then
        deallocate(y%calipso_cldtypemeanzse)
        nullify(y%calipso_cldtypemeanzse)
     endif
     if (associated(y%calipso_cldthinemis))      then
        deallocate(y%calipso_cldthinemis)
        nullify(y%calipso_cldthinemis)
     endif
     if (associated(y%calipso_lidarcld))         then
        deallocate(y%calipso_lidarcld)
        nullify(y%calipso_lidarcld)
     endif
     if (associated(y%calipso_srbval))            then
        deallocate(y%calipso_srbval)
        nullify(y%calipso_srbval)
     endif
     if (associated(y%calipso_cfad_sr))          then
        deallocate(y%calipso_cfad_sr)
        nullify(y%calipso_cfad_sr)
     endif
     if (associated(y%grLidar532_beta_mol))     then
        deallocate(y%grLidar532_beta_mol)
        nullify(y%grLidar532_beta_mol)
     endif
     if (associated(y%grLidar532_beta_tot))     then
        deallocate(y%grLidar532_beta_tot)
        nullify(y%grLidar532_beta_tot)
     endif
     if (associated(y%grLidar532_cldlayer))     then
        deallocate(y%grLidar532_cldlayer)
        nullify(y%grLidar532_cldlayer)
     endif
     if (associated(y%grLidar532_lidarcld))     then
        deallocate(y%grLidar532_lidarcld)
        nullify(y%grLidar532_lidarcld)
     endif
     if (associated(y%grLidar532_cfad_sr))      then
        deallocate(y%grLidar532_cfad_sr)
        nullify(y%grLidar532_cfad_sr)
     endif
     if (associated(y%grLidar532_srbval))       then
        deallocate(y%grLidar532_srbval)
        nullify(y%grLidar532_srbval)
     endif
     if (associated(y%atlid_beta_mol))           then
        deallocate(y%atlid_beta_mol)
        nullify(y%atlid_beta_mol)
     endif
     if (associated(y%atlid_beta_tot))           then
        deallocate(y%atlid_beta_tot)
        nullify(y%atlid_beta_tot)
     endif
     if (associated(y%atlid_cldlayer))           then
        deallocate(y%atlid_cldlayer)
        nullify(y%atlid_cldlayer)
     endif
     if (associated(y%atlid_lidarcld))           then
        deallocate(y%atlid_lidarcld)
        nullify(y%atlid_lidarcld)
     endif
     if (associated(y%atlid_cfad_sr))            then
        deallocate(y%atlid_cfad_sr)
        nullify(y%atlid_cfad_sr)
     endif
     if (associated(y%atlid_srbval))             then
        deallocate(y%atlid_srbval)
        nullify(y%atlid_srbval)
     endif
     if (associated(y%parasolPix_refl))           then
        deallocate(y%parasolPix_refl)
        nullify(y%parasolPix_refl)
     endif
     if (associated(y%parasolGrid_refl))          then
        deallocate(y%parasolGrid_refl)
        nullify(y%parasolGrid_refl)
     endif
     if (associated(y%cloudsat_Ze_tot))           then
        deallocate(y%cloudsat_Ze_tot)
        nullify(y%cloudsat_Ze_tot)
     endif
     if (associated(y%cloudsat_cfad_ze))          then
        deallocate(y%cloudsat_cfad_ze)
        nullify(y%cloudsat_cfad_ze)
     endif
     if (associated(y%cloudsat_precip_cover))     then
        deallocate(y%cloudsat_precip_cover)
        nullify(y%cloudsat_precip_cover)
     endif
     if (associated(y%cloudsat_pia))              then
        deallocate(y%cloudsat_pia)
        nullify(y%cloudsat_pia)
     endif
     if (associated(y%cloudsat_tcc))           then
        deallocate(y%cloudsat_tcc)
        nullify(y%cloudsat_tcc)
     endif
     if (associated(y%cloudsat_tcc2))           then
        deallocate(y%cloudsat_tcc2)
        nullify(y%cloudsat_tcc2)
     endif
     if (associated(y%radar_lidar_tcc))           then
        deallocate(y%radar_lidar_tcc)
        nullify(y%radar_lidar_tcc)
     endif
     if (associated(y%cloudsat_tcc))           then
        deallocate(y%cloudsat_tcc)
        nullify(y%cloudsat_tcc)
     endif
     if (associated(y%cloudsat_tcc2))           then
        deallocate(y%cloudsat_tcc2)
        nullify(y%cloudsat_tcc2)
     endif
     if (associated(y%lidar_only_freq_cloud))     then
        deallocate(y%lidar_only_freq_cloud)
        nullify(y%lidar_only_freq_cloud)
     endif
     if (associated(y%isccp_totalcldarea))        then
        deallocate(y%isccp_totalcldarea)
        nullify(y%isccp_totalcldarea)
     endif
     if (associated(y%isccp_meantb))              then
        deallocate(y%isccp_meantb)
        nullify(y%isccp_meantb)
     endif
     if (associated(y%isccp_meantbclr))           then
        deallocate(y%isccp_meantbclr)
        nullify(y%isccp_meantbclr)
     endif
     if (associated(y%isccp_meanptop))            then
        deallocate(y%isccp_meanptop)
        nullify(y%isccp_meanptop)
     endif
     if (associated(y%isccp_meantaucld))          then
        deallocate(y%isccp_meantaucld)
        nullify(y%isccp_meantaucld)
     endif
     if (associated(y%isccp_meanalbedocld))       then
        deallocate(y%isccp_meanalbedocld)
        nullify(y%isccp_meanalbedocld)
     endif
     if (associated(y%isccp_boxtau))              then
        deallocate(y%isccp_boxtau)
        nullify(y%isccp_boxtau)
     endif
     if (associated(y%isccp_boxptop))             then
        deallocate(y%isccp_boxptop)
        nullify(y%isccp_boxptop)
     endif
     if (associated(y%isccp_fq))                  then
        deallocate(y%isccp_fq)
        nullify(y%isccp_fq)
     endif
     if (associated(y%misr_fq))                   then
        deallocate(y%misr_fq)
        nullify(y%misr_fq)
     endif
     if (associated(y%misr_dist_model_layertops)) then
        deallocate(y%misr_dist_model_layertops)
        nullify(y%misr_dist_model_layertops)
     endif
     if (associated(y%misr_meanztop))             then
        deallocate(y%misr_meanztop)
        nullify(y%misr_meanztop)
     endif
     if (associated(y%misr_cldarea))              then
        deallocate(y%misr_cldarea)
        nullify(y%misr_cldarea)
     endif
     if (associated(y%rttov_tbs))                 then
        deallocate(y%rttov_tbs)
        nullify(y%rttov_tbs)
     endif
     if (associated(y%modis_Cloud_Fraction_Total_Mean))                      then
        deallocate(y%modis_Cloud_Fraction_Total_Mean)
        nullify(y%modis_Cloud_Fraction_Total_Mean)
     endif
     if (associated(y%modis_Cloud_Fraction_Ice_Mean))                        then
        deallocate(y%modis_Cloud_Fraction_Ice_Mean)
        nullify(y%modis_Cloud_Fraction_Ice_Mean)
     endif
     if (associated(y%modis_Cloud_Fraction_Water_Mean))                      then
        deallocate(y%modis_Cloud_Fraction_Water_Mean)
        nullify(y%modis_Cloud_Fraction_Water_Mean)
     endif
     if (associated(y%modis_Cloud_Fraction_High_Mean))                       then
        deallocate(y%modis_Cloud_Fraction_High_Mean)
        nullify(y%modis_Cloud_Fraction_High_Mean)
     endif
     if (associated(y%modis_Cloud_Fraction_Mid_Mean))                        then
        deallocate(y%modis_Cloud_Fraction_Mid_Mean)
        nullify(y%modis_Cloud_Fraction_Mid_Mean)
     endif
     if (associated(y%modis_Cloud_Fraction_Low_Mean))                        then
        deallocate(y%modis_Cloud_Fraction_Low_Mean)
        nullify(y%modis_Cloud_Fraction_Low_Mean)
     endif
     if (associated(y%modis_Optical_Thickness_Total_Mean))                   then
        deallocate(y%modis_Optical_Thickness_Total_Mean)
        nullify(y%modis_Optical_Thickness_Total_Mean)
     endif
     if (associated(y%modis_Optical_Thickness_Water_Mean))                   then
        deallocate(y%modis_Optical_Thickness_Water_Mean)
        nullify(y%modis_Optical_Thickness_Water_Mean)
     endif
     if (associated(y%modis_Optical_Thickness_Ice_Mean))                     then
        deallocate(y%modis_Optical_Thickness_Ice_Mean)
        nullify(y%modis_Optical_Thickness_Ice_Mean)
     endif
     if (associated(y%modis_Optical_Thickness_Total_LogMean))                then
        deallocate(y%modis_Optical_Thickness_Total_LogMean)
        nullify(y%modis_Optical_Thickness_Total_LogMean)
     endif
     if (associated(y%modis_Optical_Thickness_Water_LogMean))                then
        deallocate(y%modis_Optical_Thickness_Water_LogMean)
        nullify(y%modis_Optical_Thickness_Water_LogMean)
     endif
     if (associated(y%modis_Optical_Thickness_Ice_LogMean))                  then
        deallocate(y%modis_Optical_Thickness_Ice_LogMean)
        nullify(y%modis_Optical_Thickness_Ice_LogMean)
     endif
     if (associated(y%modis_Cloud_Particle_Size_Water_Mean))                 then
        deallocate(y%modis_Cloud_Particle_Size_Water_Mean)
        nullify(y%modis_Cloud_Particle_Size_Water_Mean)
     endif
     if (associated(y%modis_Cloud_Particle_Size_Ice_Mean))                   then
        deallocate(y%modis_Cloud_Particle_Size_Ice_Mean)
        nullify(y%modis_Cloud_Particle_Size_Ice_Mean)
     endif
     if (associated(y%modis_Cloud_Top_Pressure_Total_Mean))                  then
        deallocate(y%modis_Cloud_Top_Pressure_Total_Mean)
        nullify(y%modis_Cloud_Top_Pressure_Total_Mean)
     endif
     if (associated(y%modis_Liquid_Water_Path_Mean))                         then
        deallocate(y%modis_Liquid_Water_Path_Mean)
        nullify(y%modis_Liquid_Water_Path_Mean)
     endif
     if (associated(y%modis_Ice_Water_Path_Mean))                            then
        deallocate(y%modis_Ice_Water_Path_Mean)
        nullify(y%modis_Ice_Water_Path_Mean)
     endif
     if (associated(y%modis_Optical_Thickness_vs_Cloud_Top_Pressure))        then
        deallocate(y%modis_Optical_Thickness_vs_Cloud_Top_Pressure)
        nullify(y%modis_Optical_Thickness_vs_Cloud_Top_Pressure)
     endif
     if (associated(y%modis_Optical_thickness_vs_ReffLIQ))                   then
        deallocate(y%modis_Optical_thickness_vs_ReffLIQ)
        nullify(y%modis_Optical_thickness_vs_ReffLIQ)
     endif
     if (associated(y%modis_Optical_thickness_vs_ReffICE))                   then
        deallocate(y%modis_Optical_thickness_vs_ReffICE)
        nullify(y%modis_Optical_thickness_vs_ReffICE)
     endif
     if (associated(y%cfodd_ntotal)) then
        deallocate(y%cfodd_ntotal)
        nullify(y%cfodd_ntotal)
     endif
     if (associated(y%wr_occfreq_ntotal)) then
        deallocate(y%wr_occfreq_ntotal)
        nullify(y%wr_occfreq_ntotal)
     endif

   end subroutine destroy_cosp_outputs



  !====================================================================================================
  ! SUBROUTINE subsample_and_optics
  !
  ! subroutine to call subsample_and_optics
  !====================================================================================================
   subroutine subsample_and_optics(nPoints, nLevels, nColumns, nHydro, overlap, use_vgrid,   &
                                   use_precipitation_fluxes, lidar_ice_type, sd, tca, cca,   &
                                   fl_lsrainIN, fl_lssnowIN, fl_lsgrplIN, fl_ccrainIN,       &
                                   fl_ccsnowIN, mr_lsliq, mr_lsice, mr_ccliq, mr_ccice,      &
                                   reffIN, dtau_c, dtau_s, dem_c, dem_s, cospstateIN,        &
                                   cospIN) !, &

    ! Inputs
    integer,intent(in) :: nPoints, nLevels, nColumns, nHydro, overlap, lidar_ice_type
    real(wp),intent(in),dimension(nPoints,nLevels) :: tca,cca,mr_lsliq,mr_lsice,mr_ccliq,   &
         mr_ccice,dtau_c,dtau_s,dem_c,dem_s,fl_lsrainIN,fl_lssnowIN,fl_lsgrplIN,fl_ccrainIN,&
         fl_ccsnowIN
    real(wp),intent(in),dimension(nPoints,nLevels,nHydro) :: reffIN
    logical,intent(in) :: use_vgrid ! .false.: outputs on model levels
                                    ! .true.:  outputs on evenly-spaced vertical levels.
    logical,intent(in) :: use_precipitation_fluxes
    type(size_distribution),intent(inout) :: sd

    ! Outputs
    type(cosp_optical_inputs),intent(inout) :: cospIN
    type(cosp_column_inputs),intent(inout)  :: cospstateIN

    ! Local variables
    !type(radar_cfg) ::  rcfg_cloudsat     ! Radar configuration SONNY

    type(rng_state),allocatable,dimension(:) :: rngs  ! Seeds for random number generator
    integer,dimension(:),allocatable :: seed
    integer,dimension(:),allocatable :: cloudsat_preclvl_index
    integer :: i,j,k
    real(wp) :: zstep
    real(wp),dimension(:,:), allocatable :: &
         ls_p_rate, cv_p_rate, frac_ls, frac_cv, prec_ls, prec_cv,g_vol
    real(wp),dimension(:,:,:),  allocatable :: &
         frac_prec, MODIS_cloudWater, MODIS_cloudIce, fracPrecipIce, fracPrecipIce_statGrid,&
         MODIS_watersize,MODIS_iceSize, MODIS_opticalThicknessLiq,MODIS_opticalThicknessIce
    real(wp),dimension(:,:,:,:),allocatable :: &
         mr_hydro, Reff, Np
    real(wp),dimension(nPoints,nLevels) :: &
         column_frac_out, column_prec_out, fl_lsrain, fl_lssnow, fl_lsgrpl, fl_ccrain, fl_ccsnow
    !real(wp),dimension(nPoints,nColumns,Nlvgrid_local) :: tempOut
    real(wp),dimension(nPoints,nColumns,Nlvgrid_local) :: tempOut
    logical :: cmpGases=.true.
   
    !print*, 'reffIN:', maxval(reffIN), minval(reffIN)
    !print*, 'ReffIN:', maxval(ReffIN), minval(ReffIN)
    
    if (Ncolumns .gt. 1) then
       !%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
       ! Generate subcolumns for clouds (SCOPS) and precipitation type (PREC_SCOPS)
       !%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
       ! RNG used for subcolumn generation
       allocate(rngs(nPoints),seed(nPoints))
       seed(:)=0
       seed = int(cospstateIN%phalf(:,Nlevels+1))  ! In case of NPoints=1
       ! *NOTE* Chunking will change the seed
       if (NPoints .gt. 1) seed=int((cospstateIN%phalf(:,Nlevels+1)-minval(cospstateIN%phalf(:,Nlevels+1)))/      &
            (maxval(cospstateIN%phalf(:,Nlevels+1))-minval(cospstateIN%phalf(:,Nlevels+1)))*100000) + 1
       call init_rng(rngs, seed)

       ! Call scops
       call scops(NPoints,Nlevels,Ncolumns,rngs,tca,cca,overlap,cospIN%frac_out,0)
       deallocate(seed,rngs)

       ! Sum up precipitation rates
       allocate(ls_p_rate(nPoints,nLevels),cv_p_rate(nPoints,Nlevels))
       if(use_precipitation_fluxes) then
          ls_p_rate(:,1:nLevels) = fl_lsrainIN + fl_lssnowIN + fl_lsgrplIN
          cv_p_rate(:,1:nLevels) = fl_ccrainIN + fl_ccsnowIN
       else
          ls_p_rate(:,1:nLevels) = 0 ! mixing_ratio(rain) + mixing_ratio(snow) + mixing_ratio (groupel)
          cv_p_rate(:,1:nLevels) = 0 ! mixing_ratio(rain) + mixing_ratio(snow)
       endif

       ! Call PREC_SCOPS
       allocate(frac_prec(nPoints,nColumns,nLevels))
       call prec_scops(nPoints,nLevels,nColumns,ls_p_rate,cv_p_rate,cospIN%frac_out,frac_prec)
       deallocate(ls_p_rate,cv_p_rate)

       !%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
       ! Compute fraction in each gridbox for precipitation  and cloud type.
       !%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
       ! Allocate
       allocate(frac_ls(nPoints,nLevels),prec_ls(nPoints,nLevels),                       &
                frac_cv(nPoints,nLevels),prec_cv(nPoints,nLevels))

       ! Initialize
       frac_ls(1:nPoints,1:nLevels) = 0._wp
       prec_ls(1:nPoints,1:nLevels) = 0._wp
       frac_cv(1:nPoints,1:nLevels) = 0._wp
       prec_cv(1:nPoints,1:nLevels) = 0._wp
       do j=1,nPoints
          do k=1,nLevels
             do i=1,nColumns
                if (cospIN%frac_out(j,i,k)  .eq. 1)  frac_ls(j,k) = frac_ls(j,k)+1._wp
                if (cospIN%frac_out(j,i,k)  .eq. 2)  frac_cv(j,k) = frac_cv(j,k)+1._wp
                if (frac_prec(j,i,k) .eq. 1)  prec_ls(j,k) = prec_ls(j,k)+1._wp
                if (frac_prec(j,i,k) .eq. 2)  prec_cv(j,k) = prec_cv(j,k)+1._wp
                if (frac_prec(j,i,k) .eq. 3)  prec_cv(j,k) = prec_cv(j,k)+1._wp
                if (frac_prec(j,i,k) .eq. 3)  prec_ls(j,k) = prec_ls(j,k)+1._wp
             enddo
             frac_ls(j,k)=frac_ls(j,k)/nColumns
             frac_cv(j,k)=frac_cv(j,k)/nColumns
             prec_ls(j,k)=prec_ls(j,k)/nColumns
             prec_cv(j,k)=prec_cv(j,k)/nColumns
          enddo
       enddo

       !%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
       ! Assign gridmean mixing-ratios (mr_XXXXX), effective radius (ReffIN) and number
       ! concentration (not defined) to appropriate sub-column. Here we are using scops.
       !%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
       allocate(mr_hydro(nPoints,nColumns,nLevels,nHydro),                               &
                Reff(nPoints,nColumns,nLevels,nHydro),                                   &
                Np(nPoints,nColumns,nLevels,nHydro))

       ! Initialize
       mr_hydro(:,:,:,:) = 0._wp
       Reff(:,:,:,:)     = 0._wp
       Np(:,:,:,:)       = 0._wp
       do k=1,nColumns
          ! Subcolumn cloud fraction
          column_frac_out = cospIN%frac_out(:,k,:)

          ! LS clouds
          where (column_frac_out == I_LSC)
             mr_hydro(:,k,:,I_LSCLIQ) = mr_lsliq
             mr_hydro(:,k,:,I_LSCICE) = mr_lsice
             Reff(:,k,:,I_LSCLIQ)     = ReffIN(:,:,I_LSCLIQ)
             Reff(:,k,:,I_LSCICE)     = ReffIN(:,:,I_LSCICE)
          ! CONV clouds
          elsewhere (column_frac_out == I_CVC)
             mr_hydro(:,k,:,I_CVCLIQ) = mr_ccliq
             mr_hydro(:,k,:,I_CVCICE) = mr_ccice
             Reff(:,k,:,I_CVCLIQ)     = ReffIN(:,:,I_CVCLIQ)
             Reff(:,k,:,I_CVCICE)     = ReffIN(:,:,I_CVCICE)
          end where

          ! Subcolumn precipitation
          column_prec_out = frac_prec(:,k,:)

          ! LS Precipitation
          where ((column_prec_out == 1) .or. (column_prec_out == 3) )
             Reff(:,k,:,I_LSRAIN) = ReffIN(:,:,I_LSRAIN)
             Reff(:,k,:,I_LSSNOW) = ReffIN(:,:,I_LSSNOW)
             Reff(:,k,:,I_LSGRPL) = ReffIN(:,:,I_LSGRPL)
             ! CONV precipitation
          elsewhere ((column_prec_out == 2) .or. (column_prec_out == 3))
             Reff(:,k,:,I_CVRAIN) = ReffIN(:,:,I_CVRAIN)
             Reff(:,k,:,I_CVSNOW) = ReffIN(:,:,I_CVSNOW)
          end where
       enddo
       
       !%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
       ! Convert the subcolumn mixing ratio and precipitation fluxes from gridbox mean
       ! values to fraction-based values.
       !%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
       ! Initialize
       fl_lsrain(:,:) = 0._wp
       fl_lssnow(:,:) = 0._wp
       fl_lsgrpl(:,:) = 0._wp
       fl_ccrain(:,:) = 0._wp
       fl_ccsnow(:,:) = 0._wp
       do k=1,nLevels
          do j=1,nPoints
             ! In-cloud mixing ratios.
             if (frac_ls(j,k) .ne. 0.) then
                mr_hydro(j,:,k,I_LSCLIQ) = mr_hydro(j,:,k,I_LSCLIQ)/frac_ls(j,k)
                mr_hydro(j,:,k,I_LSCICE) = mr_hydro(j,:,k,I_LSCICE)/frac_ls(j,k)
             endif
             if (frac_cv(j,k) .ne. 0.) then
                mr_hydro(j,:,k,I_CVCLIQ) = mr_hydro(j,:,k,I_CVCLIQ)/frac_cv(j,k)
                mr_hydro(j,:,k,I_CVCICE) = mr_hydro(j,:,k,I_CVCICE)/frac_cv(j,k)
             endif
             ! Precipitation
             if (use_precipitation_fluxes) then
                if (prec_ls(j,k) .ne. 0.) then
                   fl_lsrain(j,k) = fl_lsrainIN(j,k)/prec_ls(j,k)
                   fl_lssnow(j,k) = fl_lssnowIN(j,k)/prec_ls(j,k)
                   fl_lsgrpl(j,k) = fl_lsgrplIN(j,k)/prec_ls(j,k)
                endif
                if (prec_cv(j,k) .ne. 0.) then
                   fl_ccrain(j,k) = fl_ccrainIN(j,k)/prec_cv(j,k)
                   fl_ccsnow(j,k) = fl_ccsnowIN(j,k)/prec_cv(j,k)
                endif
             else
                if (prec_ls(j,k) .ne. 0.) then
                   mr_hydro(j,:,k,I_LSRAIN) = mr_hydro(j,:,k,I_LSRAIN)/prec_ls(j,k)
                   mr_hydro(j,:,k,I_LSSNOW) = mr_hydro(j,:,k,I_LSSNOW)/prec_ls(j,k)
                   mr_hydro(j,:,k,I_LSGRPL) = mr_hydro(j,:,k,I_LSGRPL)/prec_ls(j,k)
                endif
                if (prec_cv(j,k) .ne. 0.) then
                   mr_hydro(j,:,k,I_CVRAIN) = mr_hydro(j,:,k,I_CVRAIN)/prec_cv(j,k)
                   mr_hydro(j,:,k,I_CVSNOW) = mr_hydro(j,:,k,I_CVSNOW)/prec_cv(j,k)
                endif
             endif
          enddo
       enddo
       deallocate(frac_ls,prec_ls,frac_cv,prec_cv)

       !%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
       ! Convert precipitation fluxes to mixing ratios
       !%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
       if (use_precipitation_fluxes) then
          ! LS rain
          call cosp_precip_mxratio(nPoints, nLevels, nColumns, cospstateIN%pfull,        &
               cospstateIN%at, frac_prec, 1._wp, n_ax(I_LSRAIN), n_bx(I_LSRAIN),         &
               alpha_x(I_LSRAIN), c_x(I_LSRAIN),   d_x(I_LSRAIN),   g_x(I_LSRAIN),       &
               a_x(I_LSRAIN),   b_x(I_LSRAIN),   gamma_1(I_LSRAIN), gamma_2(I_LSRAIN),   &
               gamma_3(I_LSRAIN), gamma_4(I_LSRAIN), fl_lsrain,                          &
               mr_hydro(:,:,:,I_LSRAIN), Reff(:,:,:,I_LSRAIN))
          ! LS snow
          call cosp_precip_mxratio(nPoints, nLevels, nColumns, cospstateIN%pfull,        &
               cospstateIN%at, frac_prec, 1._wp,  n_ax(I_LSSNOW),  n_bx(I_LSSNOW),       &
               alpha_x(I_LSSNOW), c_x(I_LSSNOW),  d_x(I_LSSNOW),  g_x(I_LSSNOW),         &
               a_x(I_LSSNOW),   b_x(I_LSSNOW),   gamma_1(I_LSSNOW),  gamma_2(I_LSSNOW),  &
               gamma_3(I_LSSNOW), gamma_4(I_LSSNOW), fl_lssnow,                          &
               mr_hydro(:,:,:,I_LSSNOW), Reff(:,:,:,I_LSSNOW))
          ! CV rain
          call cosp_precip_mxratio(nPoints, nLevels, nColumns, cospstateIN%pfull,        &
               cospstateIN%at, frac_prec, 2._wp, n_ax(I_CVRAIN),  n_bx(I_CVRAIN),        &
               alpha_x(I_CVRAIN), c_x(I_CVRAIN),   d_x(I_CVRAIN),   g_x(I_CVRAIN),       &
               a_x(I_CVRAIN),   b_x(I_CVRAIN),   gamma_1(I_CVRAIN), gamma_2(I_CVRAIN),   &
               gamma_3(I_CVRAIN), gamma_4(I_CVRAIN), fl_ccrain,                          &
               mr_hydro(:,:,:,I_CVRAIN), Reff(:,:,:,I_CVRAIN))
          ! CV snow
          call cosp_precip_mxratio(nPoints, nLevels, nColumns, cospstateIN%pfull,        &
               cospstateIN%at, frac_prec, 2._wp, n_ax(I_CVSNOW),  n_bx(I_CVSNOW),        &
               alpha_x(I_CVSNOW),  c_x(I_CVSNOW),   d_x(I_CVSNOW),   g_x(I_CVSNOW),      &
               a_x(I_CVSNOW),   b_x(I_CVSNOW),   gamma_1(I_CVSNOW), gamma_2(I_CVSNOW),   &
               gamma_3(I_CVSNOW), gamma_4(I_CVSNOW), fl_ccsnow,                          &
               mr_hydro(:,:,:,I_CVSNOW), Reff(:,:,:,I_CVSNOW))
          ! LS groupel.
          call cosp_precip_mxratio(nPoints, nLevels, nColumns, cospstateIN%pfull,        &
               cospstateIN%at, frac_prec, 1._wp, n_ax(I_LSGRPL),  n_bx(I_LSGRPL),        &
               alpha_x(I_LSGRPL), c_x(I_LSGRPL),   d_x(I_LSGRPL),   g_x(I_LSGRPL),       &
               a_x(I_LSGRPL),   b_x(I_LSGRPL),   gamma_1(I_LSGRPL),  gamma_2(I_LSGRPL),  &
               gamma_3(I_LSGRPL), gamma_4(I_LSGRPL), fl_lsgrpl,                          &
               mr_hydro(:,:,:,I_LSGRPL), Reff(:,:,:,I_LSGRPL))
          deallocate(frac_prec)
       endif

    else
       cospIN%frac_out(:,:,:) = 1
       allocate(mr_hydro(nPoints,1,nLevels,nHydro),Reff(nPoints,1,nLevels,nHydro),       &
                Np(nPoints,1,nLevels,nHydro))
       mr_hydro(:,1,:,I_LSCLIQ) = mr_lsliq
       mr_hydro(:,1,:,I_LSCICE) = mr_lsice
       mr_hydro(:,1,:,I_CVCLIQ) = mr_ccliq
       mr_hydro(:,1,:,I_CVCICE) = mr_ccice
       Reff(:,1,:,:)            = ReffIN
    endif

    !%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    ! 11 micron emissivity
    !%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    if (Lisccp) then
       call cosp_simulator_optics(nPoints,nColumns,nLevels,cospIN%frac_out,dem_c,dem_s,    &
                                  cospIN%emiss_11)
    endif
    !%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    ! 0.67 micron optical depth
    !%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    if (Lisccp .or. Lmisr .or. Lmodis) then
       call cosp_simulator_optics(nPoints,nColumns,nLevels,cospIN%frac_out,dtau_c,dtau_s,  &
                                  cospIN%tau_067)
    endif
    !%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    ! LIDAR Polarized optics
    !%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    !print*, 'Lcalipso LIDAR.................',Lcalipso  != T so it's ok here
    ! WRONG HERE
    if (Lcalipso) then
       call lidar_optics(nPoints, nColumns, nLevels, 4, lidar_ice_type, 532, .false.,      &
            mr_hydro(:,:,:,I_LSCLIQ),  mr_hydro(:,:,:,I_LSCICE), mr_hydro(:,:,:,I_CVCLIQ), &
            mr_hydro(:,:,:,I_CVCICE), ReffIN(:,:,I_LSCLIQ), ReffIN(:,:,I_LSCICE),          &
            ReffIN(:,:,I_CVCLIQ), ReffIN(:,:,I_CVCICE), cospstateIN%pfull,                 &
            cospstateIN%phalf, cospstateIN%at, cospIN%beta_mol_calipso,                    &
            cospIN%betatot_calipso, cospIN%tau_mol_calipso, cospIN%tautot_calipso,         &
            cospIN%tautot_S_liq, cospIN%tautot_S_ice, cospIN%betatot_ice_calipso,          &
            cospIN%betatot_liq_calipso, cospIN%tautot_ice_calipso, cospIN%tautot_liq_calipso)
    endif

    if (LgrLidar532) then
       call lidar_optics(nPoints, nColumns, nLevels, 4, lidar_ice_type, 532, .true.,       &
            mr_hydro(:,:,:,I_LSCLIQ),  mr_hydro(:,:,:,I_LSCICE), mr_hydro(:,:,:,I_CVCLIQ), &
            mr_hydro(:,:,:,I_CVCICE), ReffIN(:,:,I_LSCLIQ), ReffIN(:,:,I_LSCICE),          &
            ReffIN(:,:,I_CVCLIQ), ReffIN(:,:,I_CVCICE), cospstateIN%pfull,                 &
            cospstateIN%phalf, cospstateIN%at, cospIN%beta_mol_grLidar532,                 &
            cospIN%betatot_grLidar532, cospIN%tau_mol_grLidar532, cospIN%tautot_grLidar532)
    endif

    if (Latlid) then
       call lidar_optics(nPoints, nColumns, nLevels, 4, lidar_ice_type, 355, .false.,      &
            mr_hydro(:,:,:,I_LSCLIQ),  mr_hydro(:,:,:,I_LSCICE), mr_hydro(:,:,:,I_CVCLIQ), &
            mr_hydro(:,:,:,I_CVCICE), ReffIN(:,:,I_LSCLIQ), ReffIN(:,:,I_LSCICE),          &
            ReffIN(:,:,I_CVCLIQ), ReffIN(:,:,I_CVCICE), cospstateIN%pfull,                 &
            cospstateIN%phalf, cospstateIN%at, cospIN%beta_mol_atlid, cospIN%betatot_atlid,&
            cospIN%tau_mol_atlid, cospIN%tautot_atlid)
    endif

    !%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    ! CLOUDSAT RADAR OPTICS
    !%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    if (lcloudsat) then

       ! Compute gaseous absorption (assume identical for each subcolun)
       allocate(g_vol(nPoints,nLevels))
       g_vol(:,:)=0._wp
       do i=1,nPoints
          do j=1,nLevels
             if (rcfg_cloudsat%use_gas_abs == 1 .or. (rcfg_cloudsat%use_gas_abs == 2 .and. j .eq. 1)) then
                g_vol(i,j) = gases(cospstateIN%pfull(i,j), cospstateIN%at(i,j),cospstateIN%qv(i,j),rcfg_cloudsat%freq)
             endif
             cospIN%g_vol_cloudsat(i,:,j)=g_vol(i,j)
          end do
       end do

       ! Loop over all subcolumns
       allocate(fracPrecipIce(nPoints,nColumns,nLevels))
       fracPrecipIce(:,:,:) = 0._wp
       do k=1,nColumns
          call quickbeam_optics(sd, rcfg_cloudsat, nPoints, nLevels, R_UNDEF,  &
               mr_hydro(:,k,:,1:nHydro)*1000._wp, Reff(:,k,:,1:nHydro)*1.e6_wp,&
               !mr_hydro(:,k,:,1:nHydro), Reff(:,k,:,1:nHydro),&
               Np(:,k,:,1:nHydro), cospstateIN%pfull, cospstateIN%at,          &
               cospstateIN%qv, cospIN%z_vol_cloudsat(1:nPoints,k,:),           &
               cospIN%kr_vol_cloudsat(1:nPoints,k,:))

          ! At each model level, what fraction of the precipitation is frozen?
          where(mr_hydro(:,k,:,I_LSRAIN) .gt. 0 .or. mr_hydro(:,k,:,I_LSSNOW) .gt. 0 .or. &
                mr_hydro(:,k,:,I_CVRAIN) .gt. 0 .or. mr_hydro(:,k,:,I_CVSNOW) .gt. 0 .or. &
                mr_hydro(:,k,:,I_LSGRPL) .gt. 0)
             fracPrecipIce(:,k,:) = (mr_hydro(:,k,:,I_LSSNOW) + mr_hydro(:,k,:,I_CVSNOW) + &
                  mr_hydro(:,k,:,I_LSGRPL)) / &
                  (mr_hydro(:,k,:,I_LSSNOW) + mr_hydro(:,k,:,I_CVSNOW) + mr_hydro(:,k,:,I_LSGRPL) + &
                  mr_hydro(:,k,:,I_LSRAIN)  + mr_hydro(:,k,:,I_CVRAIN))
          elsewhere
             fracPrecipIce(:,k,:) = 0._wp
          endwhere
       enddo

       ! Regrid frozen fraction to Cloudsat/Calipso statistical grid
       if (use_vgrid) then
         allocate(fracPrecipIce_statGrid(nPoints,nColumns,Nlvgrid_local))
         fracPrecipIce_statGrid(:,:,:) = 0._wp
          
         call cosp_change_vertical_grid(Npoints, Ncolumns, Nlevels, cospstateIN%hgt_matrix(:,Nlevels:1:-1), &
              cospstateIN%hgt_matrix_half(:,Nlevels:1:-1), fracPrecipIce(:,:,Nlevels:1:-1), Nlvgrid_local,  &
              vgrid_zl(Nlvgrid_local:1:-1), vgrid_zu(Nlvgrid_local:1:-1), fracPrecipIce_statGrid(:,:,Nlvgrid_local:1:-1))

         ! Find proper layer above de surface elevation to compute precip flags in Cloudsat/Calipso statistical grid
         allocate(cloudsat_preclvl_index(nPoints))
         cloudsat_preclvl_index(:) = 0._wp
         ! Compute the zstep distance between two atmopsheric layers
         zstep = vgrid_zl(1)-vgrid_zl(2)
         ! Computing altitude index for precip flags calculation (one layer above surfelev layer)
         cloudsat_preclvl_index(:) = cloudsat_preclvl - floor( cospstateIN%surfelev(:)/zstep )

         ! For near-surface diagnostics, we only need the frozen fraction at one layer.
         do i=1,nPoints
           cospIN%fracPrecipIce(i,:) = fracPrecipIce_statGrid(i,:,cloudsat_preclvl_index(i))
         enddo
         deallocate(cloudsat_preclvl_index)
         deallocate(fracPrecipIce_statGrid)
       endif

    endif

    !%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    ! MODIS optics
    !%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    if (Lmodis) then
       allocate(MODIS_cloudWater(nPoints,nColumns,nLevels),                                &
                MODIS_cloudIce(nPoints,nColumns,nLevels),                                  &
                MODIS_waterSize(nPoints,nColumns,nLevels),                                 &
                MODIS_iceSize(nPoints,nColumns,nLevels),                                   &
                MODIS_opticalThicknessLiq(nPoints,nColumns,nLevels),                       &
                MODIS_opticalThicknessIce(nPoints,nColumns,nLevels))
       ! Cloud water
       call cosp_simulator_optics(nPoints,nColumns,nLevels,cospIN%frac_out,                &
            mr_hydro(:,:,:,I_CVCLIQ),mr_hydro(:,:,:,I_LSCLIQ),MODIS_cloudWater)
       ! Cloud ice
       call cosp_simulator_optics(nPoints,nColumns,nLevels,cospIN%frac_out,                &
            mr_hydro(:,:,:,I_CVCICE),mr_hydro(:,:,:,I_LSCICE),MODIS_cloudIce)
       ! Water droplet size
       call cosp_simulator_optics(nPoints,nColumns,nLevels,cospIN%frac_out,                &
            Reff(:,:,:,I_CVCLIQ),Reff(:,:,:,I_LSCLIQ),MODIS_waterSize)
       ! Ice crystal size
       call cosp_simulator_optics(nPoints,nColumns,nLevels,cospIN%frac_out,                &
            Reff(:,:,:,I_CVCICE),Reff(:,:,:,I_LSCICE),MODIS_iceSize)

       ! Partition optical thickness into liquid and ice parts
       call modis_optics_partition(nPoints, nLevels, nColumns, MODIS_cloudWater,           &
            MODIS_cloudIce, MODIS_waterSize, MODIS_iceSize, cospIN%tau_067,                &
            MODIS_opticalThicknessLiq, MODIS_opticalThicknessIce)

       ! Compute assymetry parameter and single scattering albedo
       call modis_optics(nPoints, nLevels, nColumns, MODIS_opticalThicknessLiq,            &
            MODIS_waterSize*1.0e6_wp, MODIS_opticalThicknessIce,                           &
            MODIS_iceSize*1.0e6_wp, cospIN%fracLiq, cospIN%asym, cospIN%ss_alb)

       ! Deallocate memory
       deallocate(MODIS_cloudWater,MODIS_cloudIce,MODIS_WaterSize,MODIS_iceSize,           &
            MODIS_opticalThicknessLiq,MODIS_opticalThicknessIce,mr_hydro,                  &
            Np,Reff)
    endif
    !print*,'INSIDE subsample_and_optics.............', nPoints, nLevels, nColumns


  end subroutine subsample_and_optics
#endif
end module module_ctrl_microphysics

