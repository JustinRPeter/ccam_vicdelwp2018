FC = mpif90

# Common compiler flags
FFLAGS = -xHost -ftz -fpp -I $(NETCDF_ROOT)/include -Dsumdd

# Options for building with VAMPIRTrace
ifeq ($(VT),yes)
FC = vtfort -vt:fc mpif90 -vt:inst manual
FFLAGS += -Dvampir -DVTRACE
else
FFLAGS += -Dsimple_timer 
endif


#Decomposition method
ifeq ($(DECOMP),uniform)
FFLAGS += -Duniform_decomp
endif

# Testing - I/O and fpmodel
ifeq ($(TEST),yes)
FFLAGS += -assume buffered_io -fp-model strict -Doutsync
endif

# Build with 64 ints/reals
ifeq ($(I8R8),yes)
FFLAGS += -r8 -i8 -Di8r8
endif

LIBS = -L $(NETCDF_ROOT)/lib -L $(HDF5_HOME)/lib -lnetcdf -lnetcdff -lhdf5 -lhdf5_hl

LDFLAGS = 

OBJS = adjust5.o amipsst.o conjob.o convjlm.o depts.o esbda.o gettin.o \
globpe.o gwdrag.o hordifg.o hs_phys.o iabsdate.o indata.o infile.o ints.o \
helmsol.o jimcc.o helmsor.o optmx.o mslp.o nestin.o nonlin.o \
outcdf.o outfile.o pbldif.o radriv90.o retopo.o scrnout.o setxyz.o sflux.o \
soilsnow.o staguv.o trim.o upglobal.o eig.o updps.o vadv30.o vadvtvd.o \
vertmix.o esibda.o icefall.o leoncld.o newcloud.o newrain.o latltoij.o \
cldblk.o clddia.o cldset.o clo89.o cloud.o cloud2.o co2_read.o e1e288.o \
e3v88.o fst88.o hconst.o lwr88.o ozoneread.o resetd.o spa88.o \
swr99.o table.o zenith.o cc_mpi.o diag_m.o sumdd_m.o ilu_m.o davies.o \
utilities.o onthefly.o o3read_amip.o o3set_amip.o tracermodule.o timeseries.o \
trvmix.o mgsolve.o betts.o bett_cuc.o bettinit.o bettrain.o bettspli.o \
mpif_m.o netcdf_m.o stacklimit.o \
xyzinfo_m.o vecsuv_m.o map_m.o latlong_m.o indices_m.o bigxy4_m.o \
arrays_m.o betts1_m.o carbpools_m.o cldcom_m.o co2dta_m.o cfrac_m.o dava_m.o \
davb_m.o dpsdt_m.o epst_m.o extraout_m.o gdrag_m.o histave_m.o kdacom_m.o \
kuocomb_m.o liqwpar_m.o lwout_m.o morepbl_m.o nharrs_m.o nlin_m.o \
nsibd_m.o o3amip_m.o parmhdff_m.o pbl_m.o permsurf_m.o prec_m.o raddiag_m.o \
radisw_m.o rdflux_m.o savuvt_m.o savuv1_m.o sbar_m.o screen_m.o sigs_m.o \
soil_m.o soilsnow_m.o srccom_m.o swocom_m.o tabcom_m.o \
tbar2d_m.o tfcom_m.o tracers_m.o unn_m.o uvbar_m.o vecs_m.o vegpar_m.o vvel_m.o \
workglob_m.o work2_m.o work3_m.o work3b_m.o work3f_m.o work3lwr_m.o work3sav_m.o \
xarrs_m.o \
aerointerface.o aerosolldr.o \
cable_air.o cable_albedo.o cable_canopy.o cable_carbon.o cable_ccam2.o cable_common.o \
cable_data.o cable_define_types.o cable_radiation.o cable_roughness.o cable_soilsnow.o \
casa_cnp.o casa_variable.o \
ateb.o mlo.o mlodynamics.o tkeeps.o \
seaesfrad.o rad_utilities.o microphys_rad.o esfsw_driver.o esfsw_parameters.o \
longwave_params.o sealw99.o longwave_clouds.o longwave_fluxes.o longwave_tables.o \
optical_path.o gas_tf.o lw_gases_stdtf.o

globpea: $(OBJS)
	$(FC) -o globpea $(FFLAGS) $(LDFLAGS) $(OBJS) $(LIBS)

clean:
	rm *.o *.mod globpea

.SUFFIXES:.f90 .F90

mpif_m.o: mpif_m.f90
	$(FC) -c $<
netcdf_m.o: netcdf_m.f90
	$(FC) -c -I $(NETCDF_ROOT)/include $<
esfsw_driver.o: esfsw_driver.f90
	$(FC)  -c -r8 $(FFLAGS) $<
esfsw_parameters.o: esfsw_parameters.f90
	$(FC)  -c -r8 $(FFLAGS) $<
gas_tf.o: gas_tf.f90
	$(FC)  -c -r8 $(FFLAGS) $<
longwave_clouds.o: longwave_clouds.f90
	$(FC)  -c -r8 $(FFLAGS) $<
longwave_fluxes.o: longwave_fluxes.f90
	$(FC)  -c -r8 $(FFLAGS) $<
longwave_tables.o: longwave_tables.f90
	$(FC)  -c -r8 $(FFLAGS) $<
longwave_params.o: longwave_params.f90
	$(FC)  -c -r8 $(FFLAGS) $<
lw_gases_stdtf.o: lw_gases_stdtf.f90
	$(FC)  -c -r8 $(FFLAGS) $<
microphys_rad.o: microphys_rad.f90
	$(FC)  -c -r8 $(FFLAGS) $<
optical_path.o: optical_path.f90
	$(FC)  -c -r8 $(FFLAGS) $<
rad_utilities.o: rad_utilities.f90
	$(FC)  -c -r8 $(FFLAGS) $<
sealw99.o: sealw99.f90
	$(FC)  -c -r8 $(FFLAGS) $<
sumdd_m.o: sumdd_m.f90
	$(FC)  -c -fp-model precise $(FFLAGS) $<
stacklimit.o: stacklimit.c
	cc -c stacklimit.c


.f90.o:
	$(FC) -c $(FFLAGS) $<
.F90.o:
	$(FC) -c $(FFLAGS) $<	
.f.o:
	$(FC) -c $(FFLAGS) $<

# Remove mod rule from Modula 2 so GNU make doesn't get confused
%.o : %.mod

# Dependencies
adjust5.o : aerosolldr.o arrays_m.o cc_mpi.o cfrac_m.o diag_m.o dpsdt_m.o epst_m.o indices_m.o liqwpar_m.o map_m.o mgsolve.o morepbl_m.o nharrs_m.o nlin_m.o pbl_m.o sigs_m.o tbar2d_m.o tracermodule.o tracers_m.o vecsuv_m.o vecs_m.o vvel_m.o work3sav_m.o xarrs_m.o xyzinfo_m.o const_phys.h kuocom.h newmpar.h parm.h parmdyn.h parmvert.h
aerointerface.o : aerosolldr.o arrays_m.o cc_mpi.o cfrac_m.o extraout_m.o infile.o kuocomb_m.o latlong_m.o liqwpar_m.o map_m.o morepbl_m.o nharrs_m.o nsibd_m.o ozoneread.o pbl_m.o screen_m.o sigs_m.o soil_m.o soilsnow_m.o vegpar_m.o work2_m.o zenith.o const_phys.h cparams.h kuocom.h newmpar.h parm.h parmgeom.h soilv.h
amipsst.o : arrays_m.o cc_mpi.o infile.o latlong_m.o mlo.o pbl_m.o permsurf_m.o soil_m.o soilsnow_m.o dates.h filnames.h newmpar.h parm.h parmgeom.h
bett_cuc.o : betts1_m.o newmpar.h 
bettinit.o : betts1_m.o newmpar.h 
bettrain.o : betts1_m.o newmpar.h 
betts.o : betts1_m.o morepbl_m.o prec_m.o sigs_m.o newmpar.h parm.h
cable_air.o : cable_common.o cable_data.o cable_define_types.o 
cable_albedo.o : cable_common.o cable_data.o cable_define_types.o 
cable_canopy.o : cable_air.o cable_common.o cable_data.o cable_define_types.o cable_radiation.o
cable_carbon.o : cable_common.o cable_data.o cable_define_types.o
cable_common.o : cable_define_types.o
cable_ccam2.o : arrays_m.o cable_air.o cable_albedo.o cable_canopy.o cable_carbon.o cable_common.o cable_define_types.o cable_radiation.o cable_roughness.o cable_soilsnow.o carbpools_m.o casa_cnp.o casa_variable.o cc_mpi.o extraout_m.o infile.o latlong_m.o morepbl_m.o nharrs_m.o nsibd_m.o pbl_m.o permsurf_m.o prec_m.o radisw_m.o screen_m.o sigs_m.o soil_m.o soilsnow_m.o tracermodule.o tracers_m.o vegpar_m.o work2_m.o work3_m.o zenith.o const_phys.h darcdf.h dates.h establ.h newmpar.h parm.h parmgeom.h soilv.h
cable_radiation.o : cable_common.o cable_data.o cable_define_types.o
cable_roughness.o : cable_common.o cable_data.o cable_define_types.o
cable_soilsnow.o : cable_common.o cable_data.o cable_define_types.o
carbpools_m.o : cable_define_types.o casa_variable.o
casa_cnp.o : cable_define_types.o casa_variable.o
casa_variable.o : cable_define_types.o
cc_mpi.o : arrays_m.o indices_m.o latlong_m.o map_m.o mpif_m.o sigs_m.o sumdd_m.o vecsuv_m.o xyzinfo_m.o newmpar.h parm.h 
clddia.o : arrays_m.o cc_mpi.o davb_m.o map_m.o morepbl_m.o pbl_m.o sigs_m.o soil_m.o vvel_m.o const_phys.h kuocom.h newmpar.h parm.h
cldset.o : const_phys.h 
clo89.o : cldcom_m.o radisw_m.o rdparm.h newmpar.h parm.h 
cloud2.o : diag_m.o cc_mpi.o radisw_m.o sigs_m.o const_phys.h cparams.h hcon.h kuocom.h newmpar.h parm.h params.h rdparm.h
cloud.o : extraout_m.o radisw_m.o newmpar.h parm.h rdparm.h
co2_read.o : cc_mpi.o co2dta_m.o radisw_m.o filnames.h newmpar.h parm.h rdparm.h
conjob.o : aerosolldr.o arrays_m.o cc_mpi.o epst_m.o kuocomb_m.o morepbl_m.o nlin_m.o prec_m.o sigs_m.o soil_m.o tkeeps.o tracers_m.o const_phys.h establ.h newmpar.h parm.h
convjlm.o : aerosolldr.o arrays_m.o cc_mpi.o cfrac_m.o diag_m.o extraout_m.o indices_m.o kuocomb_m.o latlong_m.o liqwpar_m.o map_m.o morepbl_m.o nharrs_m.o nlin_m.o pbl_m.o prec_m.o sigs_m.o soil_m.o soilsnow_m.o tkeeps.o tracers_m.o vvel_m.o work2_m.o const_phys.h establ.h kuocom.h newmpar.h parm.h parmdyn.h
davies.o : arrays_m.o cc_mpi.o dava_m.o davb_m.o sigs_m.o newmpar.h parm.h
depts.o : bigxy4_m.o cc_mpi.o indices_m.o map_m.o uvbar_m.o vecsuv_m.o work3f_m.o xyzinfo_m.o const_phys.h newmpar.h parm.h parmgeom.h
diag_m.o : cc_mpi.o sigs_m.o sumdd_m.o xyzinfo_m.o newmpar.h parm.h
e1e288.o : kdacom_m.o radisw_m.o tabcom_m.o tfcom_m.o hcon.h newmpar.h rdparm.h
e3v88.o : tabcom_m.o hcon.h newmpar.h rdparm.h
eig.o : vecs_m.o newmpar.h
esfsw_driver.o : esfsw_parameters.o rad_utilities.o
esfsw_parameters.o : rad_utilities.o
fst88.o : cc_mpi.o cldcom_m.o diag_m.o kdacom_m.o lwout_m.o radisw_m.o rdflux_m.o srccom_m.o tabcom_m.o tfcom_m.o hcon.h newmpar.h parm.h rdparm.h rnddta.h
gas_tf.o : longwave_params.o rad_utilities.o
gettin.o : arrays_m.o savuvt_m.o newmpar.h 
globpe.o : aerointerface.o aerosolldr.o arrays_m.o bigxy4_m.o carbpools_m.o cc_mpi.o cfrac_m.o dava_m.o davb_m.o diag_m.o dpsdt_m.o epst_m.o extraout_m.o gdrag_m.o histave_m.o indices_m.o infile.o kuocomb_m.o latlong_m.o liqwpar_m.o map_m.o mlo.o mlodynamics.o morepbl_m.o nharrs_m.o nlin_m.o nsibd_m.o parmhdff_m.o pbl_m.o permsurf_m.o prec_m.o raddiag_m.o savuvt_m.o savuv1_m.o sbar_m.o screen_m.o seaesfrad.o sigs_m.o soil_m.o soilsnow_m.o tbar2d_m.o timeseries.o tkeeps.o tracermodule.o tracers_m.o unn_m.o uvbar_m.o vecs_m.o vecsuv_m.o vegpar_m.o vvel_m.o workglob_m.o work2_m.o work3_m.o work3f_m.o work3sav_m.o xarrs_m.o xyzinfo_m.o const_phys.h darcdf.h dates.h establ.h filnames.h kuocom.h newmpar.h parm.h parmdyn.h parmgeom.h parmhor.h parmsurf.h parmvert.h soilv.h stime.h trcom2.h version.h
gwdrag.o : arrays_m.o gdrag_m.o morepbl_m.o nlin_m.o pbl_m.o sigs_m.o soil_m.o const_phys.h newmpar.h parm.h
hconst.o : hcon.h 
helmsol.o : cc_mpi.o ilu_m.o indices_m.o sumdd_m.o newmpar.h parm.h parmdyn.h
helmsor.o : cc_mpi.o diag_m.o ilu_m.o indices_m.o sumdd_m.o vecs_m.o newmpar.h parm.h parmdyn.h parmgeom.h
hordifg.o : aerosolldr.o arrays_m.o cc_mpi.o cfrac_m.o diag_m.o dpsdt_m.o indices_m.o liqwpar_m.o map_m.o morepbl_m.o nharrs_m.o nlin_m.o parmhdff_m.o savuvt_m.o sigs_m.o tkeeps.o vecsuv_m.o vvel_m.o const_phys.h kuocom.h newmpar.h parm.h parmdyn.h
hs_phys.o : arrays_m.o latlong_m.o nlin_m.o sigs_m.o newmpar.h parm.h 
icefall.o : cc_mpi.o kuocomb_m.o morepbl_m.o const_phys.h cparams.h kuocom.h newmpar.h parm.h params.h
ilu_m.o : cc_mpi.o indices_m.o newmpar.h
indata.o : aerointerface.o arrays_m.o ateb.o bigxy4_m.o cable_ccam2.o cc_mpi.o dava_m.o diag_m.o epst_m.o extraout_m.o gdrag_m.o indices_m.o infile.o latlong_m.o liqwpar_m.o map_m.o mlo.o mlodynamics.o morepbl_m.o nsibd_m.o pbl_m.o permsurf_m.o sigs_m.o soil_m.o soilsnow_m.o timeseries.o tracermodule.o tracers_m.o vecs_m.o vecsuv_m.o vegpar_m.o xyzinfo_m.o const_phys.h darcdf.h dates.h filnames.h newmpar.h parm.h parmdyn.h parmgeom.h soilv.h stime.h trcom2.h
infile.o : cc_mpi.o netcdf_m.o dates.h newmpar.h parm.h parmgeom.h
ints.o : cc_mpi.o indices_m.o newmpar.h parm.h parmhor.h
latltoij.o : utilities.o const_phys.h newmpar.h parm.h parmdyn.h
leoncld.o : aerointerface.o arrays_m.o cc_mpi.o diag_m.o kuocomb_m.o latlong_m.o liqwpar_m.o morepbl_m.o nharrs_m.o nlin_m.o prec_m.o sigs_m.o soil_m.o tracers_m.o vvel_m.o work3f_m.o const_phys.h cparams.h establ.h kuocom.h newmpar.h parm.h params.h
longwave_clouds.o : rad_utilities.o
longwave_fluxes.o : rad_utilities.o
longwave_tables.o : longwave_params.o rad_utilities.o
lw_gases_stdtf.o : cc_mpi.o infile.o gas_tf.o rad_utilities.o filnames.h
lwr88.o : co2dta_m.o kdacom_m.o radisw_m.o tfcom_m.o work3lwr_m.o hcon.h newmpar.h parm.h rdparm.h rnddta.h
mgsolve.o : cc_mpi.o indices_m.o newmpar.h parm.h parmdyn.h
microphys_rad.o : esfsw_parameters.o longwave_params.o rad_utilities.o
mlodynamics.o : arrays_m.o bigxy4_m.o cable_ccam2.o cc_mpi.o indices_m.o infile.o latlong_m.o map_m.o mgsolve.o mlo.o nharrs_m.o nsibd_m.o soil_m.o soilsnow_m.o vecsuv_m.o xyzinfo_m.o const_phys.h newmpar.h parm.h parmdyn.h parmhor.h soilv.h
mslp.o : cc_mpi.o sigs_m.o const_phys.h newmpar.h parm.h
nestin.o : arrays_m.o cc_mpi.o dava_m.o davb_m.o diag_m.o indices_m.o latlong_m.o map_m.o mlo.o mlodynamics.o nharrs_m.o pbl_m.o savuvt_m.o savuv1_m.o sigs_m.o soil_m.o soilsnow_m.o vecsuv_m.o work3sav_m.o xyzinfo_m.o const_phys.h darcdf.h dates.h newmpar.h parm.h parmgeom.h stime.h
newcloud.o : diag_m.o cc_mpi.o sigs_m.o const_phys.h cparams.h kuocom.h newmpar.h parm.h params.h 
newrain.o : cc_mpi.o kuocomb_m.o morepbl_m.o const_phys.h cparams.h kuocom.h newmpar.h parm.h params.h
nonlin.o : aerosolldr.o arrays_m.o cc_mpi.o diag_m.o epst_m.o indices_m.o latlong_m.o liqwpar_m.o map_m.o morepbl_m.o nharrs_m.o nlin_m.o savuvt_m.o sigs_m.o tbar2d_m.o tkeeps.o tracers_m.o unn_m.o vecsuv_m.o vvel_m.o work3sav_m.o xarrs_m.o xyzinfo_m.o const_phys.h kuocom.h newmpar.h parm.h parmdyn.h parmvert.h
o3read_amip.o : o3amip_m.o filnames.h
o3set_amip.o : o3amip_m.o const_phys.h dates.h newmpar.h
onthefly.o : aerosolldr.o ateb.o casa_variable.o carbpools_m.o cc_mpi.o cable_define_types.o extraout_m.o infile.o latlong_m.o mlo.o mlodynamics.o morepbl_m.o nharrs_m.o nsibd_m.o savuvt_m.o savuv1_m.o screen_m.o sigs_m.o soil_m.o tkeeps.o tracers_m.o utilities.o vecsuv_m.o vvel_m.o workglob_m.o work2_m.o xarrs_m.o const_phys.h darcdf.h newmpar.h parm.h parmdyn.h parmgeom.h soilv.h stime.h
optical_path.o : longwave_params.o lw_gases_stdtf.o rad_utilities.o
outcdf.o : aerointerface.o aerosolldr.o arrays_m.o ateb.o cable_ccam2.o cable_define_types.o casa_variable.o carbpools_m.o cc_mpi.o cfrac_m.o dpsdt_m.o extraout_m.o gdrag_m.o histave_m.o infile.o latlong_m.o liqwpar_m.o map_m.o mlo.o mlodynamics.o morepbl_m.o nharrs_m.o nsibd_m.o parmhdff_m.o pbl_m.o prec_m.o raddiag_m.o savuvt_m.o savuv1_m.o screen_m.o sigs_m.o soil_m.o soilsnow_m.o tkeeps.o tracermodule.o tracers_m.o vegpar_m.o vvel_m.o work2_m.o xarrs_m.o const_phys.h dates.h filnames.h kuocom.h newmpar.h parm.h parmdyn.h parmgeom.h parmhor.h parmvert.h soilv.h trcom2.h version.h
outfile.o : arrays_m.o cc_mpi.o pbl_m.o soilsnow_m.o tracers_m.o dates.h filnames.h newmpar.h parm.h
ozoneread.o : cc_mpi.o infile.o latlong_m.o const_phys.h dates.h filnames.h newmpar.h
pbldif.o : arrays_m.o cc_mpi.o cfrac_m.o diag_m.o extraout_m.o map_m.o morepbl_m.o nharrs_m.o sigs_m.o soil_m.o newmpar.h
radriv90.o : aerointerface.o arrays_m.o ateb.o cc_mpi.o cfrac_m.o cldcom_m.o co2dta_m.o diag_m.o extraout_m.o histave_m.o infile.o kdacom_m.o kuocomb_m.o latlong_m.o liqwpar_m.o lwout_m.o mlo.o nsibd_m.o ozoneread.o pbl_m.o raddiag_m.o radisw_m.o rdflux_m.o sigs_m.o soil_m.o soilsnow_m.o srccom_m.o swocom_m.o swr99.o tabcom_m.o tfcom_m.o work3f_m.o work3lwr_m.o zenith.o const_phys.h establ.h kuocom.h newmpar.h parm.h soilv.h rdparm.h hcon.h
retopo.o : cc_mpi.o diag_m.o sigs_m.o const_phys.h newmpar.h parm.h
scrnout.o : arrays_m.o cc_mpi.o diag_m.o liqwpar_m.o mlo.o morepbl_m.o nsibd_m.o pbl_m.o permsurf_m.o prec_m.o screen_m.o sigs_m.o soil_m.o soilsnow_m.o work2_m.o const_phys.h establ.h newmpar.h parm.h
seaesfrad.o : aerointerface.o aerosolldr.o arrays_m.o ateb.o cc_mpi.o cfrac_m.o esfsw_driver.o esfsw_parameters.o extraout_m.o histave_m.o infile.o latlong_m.o longwave_params.o microphys_rad.o mlo.o nharrs_m.o nsibd_m.o ozoneread.o pbl_m.o raddiag_m.o radisw_m.o rad_utilities.o sealw99.o sigs_m.o soil_m.o soilsnow_m.o work3f_m.o zenith.o const_phys.h establ.h filnames.h kuocom.h newmpar.h parm.h
sealw99.o : gas_tf.o longwave_clouds.o longwave_fluxes.o longwave_params.o longwave_tables.o lw_gases_stdtf.o optical_path.o rad_utilities.o
setxyz.o : indices_m.o latlong_m.o map_m.o utilities.o workglob_m.o const_phys.h newmpar.h parm.h
sflux.o : arrays_m.o ateb.o cable_ccam2.o cc_mpi.o diag_m.o extraout_m.o gdrag_m.o latlong_m.o liqwpar_m.o map_m.o mlo.o mlodynamics.o morepbl_m.o nharrs_m.o nsibd_m.o pbl_m.o permsurf_m.o prec_m.o savuvt_m.o screen_m.o sigs_m.o soil_m.o soilsnow_m.o vecsuv_m.o vegpar_m.o vvel_m.o work2_m.o work3_m.o xyzinfo_m.o const_phys.h dates.h establ.h newmpar.h parm.h parmgeom.h parmsurf.h soilv.h trcom2.h
soilsnow.o : arrays_m.o cc_mpi.o diag_m.o morepbl_m.o nsibd_m.o permsurf_m.o sigs_m.o soil_m.o soilsnow_m.o work2_m.o work3_m.o work3b_m.o const_phys.h newmpar.h parm.h soilv.h
spa88.o :  cldcom_m.o kdacom_m.o lwout_m.o radisw_m.o rdflux_m.o srccom_m.o tfcom_m.o hcon.h newmpar.h rdparm.h rnddta.h
staguv.o : cc_mpi.o indices_m.o map_m.o vecsuv_m.o newmpar.h parm.h parmdyn.h
swr99.o : hcon.h newmpar.h rdparm.h
table.o : radisw_m.o tabcom_m.o hcon.h newmpar.h rdparm.h rnddta.h
timeseries.o : arrays_m.o cable_define_types.o carbpools_m.o cc_mpi.o infile.o extraout_m.o morepbl_m.o pbl_m.o prec_m.o sigs_m.o soil_m.o soilsnow_m.o tracermodule.o tracers_m.o vecsuv_m.o vegpar_m.o vvel_m.o xyzinfo_m.o const_phys.h dates.h newmpar.h parmgeom.h
tracermodule.o : arrays_m.o cc_mpi.o infile.o latlong_m.o sigs_m.o sumdd_m.o tracers_m.o xyzinfo_m.o const_phys.h dates.h newmpar.h parm.h
trim.o : newmpar.h 
trvmix.o : arrays_m.o cc_mpi.o cable_ccam2.o cable_define_types.o carbpools_m.o cc_mpi.o diag_m.o nsibd_m.o sigs_m.o tracermodule.o tracers_m.o xyzinfo_m.o const_phys.h dates.h newmpar.h parm.h
updps.o : arrays_m.o cc_mpi.o diag_m.o indices_m.o map_m.o nlin_m.o savuvt_m.o savuv1_m.o sigs_m.o vecsuv_m.o vvel_m.o xarrs_m.o xyzinfo_m.o const_phys.h newmpar.h parm.h parmdyn.h parmhor.h
upglobal.o : aerosolldr.o arrays_m.o cc_mpi.o cfrac_m.o diag_m.o epst_m.o indices_m.o liqwpar_m.o map_m.o nharrs_m.o nlin_m.o sbar_m.o sigs_m.o tkeeps.o tracers_m.o unn_m.o vecsuv_m.o vvel_m.o work3f_m.o xarrs_m.o xyzinfo_m.o const_phys.h kuocom.h newmpar.h parm.h parmdyn.h parmhor.h parmvert.h
utilities.o : const_phys.h 
vadv30.o : aerosolldr.o arrays_m.o cc_mpi.o indices_m.o liqwpar_m.o map_m.o sigs_m.o tkeeps.o tracers_m.o vvel_m.o xarrs_m.o kuocom.h newmpar.h parm.h parmdyn.h parmvert.h
vadvtvd.o : aerosolldr.o arrays_m.o cc_mpi.o cfrac_m.o diag_m.o liqwpar_m.o map_m.o nharrs_m.o sigs_m.o tkeeps.o tracers_m.o vvel_m.o xarrs_m.o kuocom.h newmpar.h parm.h parmdyn.h parmvert.h
vertmix.o : aerosolldr.o arrays_m.o cc_mpi.o cfrac_m.o diag_m.o extraout_m.o indices_m.o kuocomb_m.o liqwpar_m.o map_m.o mlo.o morepbl_m.o nharrs_m.o nlin_m.o pbl_m.o permsurf_m.o savuvt_m.o screen_m.o sigs_m.o soil_m.o soilsnow_m.o tkeeps.o tracers_m.o trvmix.o const_phys.h dates.h establ.h kuocom.h newmpar.h parm.h parmdyn.h
