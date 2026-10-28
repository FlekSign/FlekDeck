//
//  SimulatorStub.c
//  StikJITHeadless
//
//  StikJIT ships for devices only, so a Simulator build leaves out everything in
//  this target but this file: a framework still needs something to link, or
//  there is nothing to embed and sign.
//

int StikJITHeadlessIsUnavailableInSimulator = 1;
