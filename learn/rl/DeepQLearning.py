__author__ = "Juan C. Caicedo, caicedo@illinois.edu"

import os
import random
import Image
import CaffeConvNetManagement as cnm
import SingleObjectLocalizer as sol
import RLConfig as config
import numpy as np

from pybrain.rl.learners.valuebased.valuebased import ValueBasedLearner

class DeepQLearning(ValueBasedLearner):

  offPolicy = True
  batchMode = True
  dataset = []

  trainingSamples = 0

  def __init__(self, alpha=0.5, gamma=0.99):
    ValueBasedLearner.__init__(self)
    self.alpha = alpha
    self.gamma = gamma
    self.netManager = cnm.CaffeConvNetManagement(config.get('networkDir'))

  def learn(self, data, controller):
    images = []
    hash = {}
    for d in data:
      images.append(d['img'])
      key = d['img'] + '_'.join(map(str, d['box'])) + '_' + str(d['A']) + '_' + str(d['R'])
      try:
        exists = hash[key]
      except:
        self.dataset.append(d)
        hash[key] = True
        #print 'State',d
    self.updateTrainingDatabase(controller)
    self.netManager.doNetworkTraining()

  def updateTrainingDatabase(self, controller):
    trainRecs, numTrain = self.netManager.readTrainingDatabase('training.txt')
    trainRecs = self.dropRecords(trainRecs, numTrain, len(self.dataset))
    valRecs, numVal = self.netManager.readTrainingDatabase('validation.txt')
    valRecs = self.dropRecords(valRecs, numVal, len(self.dataset))
    trainRecs, valRecs = self.mergeDatasetAndRecords(trainRecs, valRecs)
    trainRecs = self.computeNextMaxQ(controller, trainRecs)
    #valRecs = self.computeNextMaxQ(controller, valRecs)
    self.trainingSamples = self.netManager.saveDatabaseFile(trainRecs, 'training.txt')
    self.netManager.saveDatabaseFile(valRecs, 'validation.txt')
    self.dataset = []
    
  def dropRecords(self, rec, total, new):
    if total > config.geti('replayMemorySize'):
      drop = 0
      while drop < new:
        for k in rec.keys():
          rec[k].pop(0)
          drop += 1
    return rec

  def mergeDatasetAndRecords(self, train, val):
    numTrain = len(self.dataset)*(1 - config.getf('percentOfValidation'))
    numVal = len(self.dataset)*config.getf('percentOfValidation')
    random.shuffle( self.dataset )
    for i in range(len(self.dataset)):
      imgPath = config.get('imageDir') + self.dataset[i]['img'] + '.jpg'
      # record format: Action, reward, discountedMaxQ, x1, y1, x2, y2,
      record = [self.dataset[i]['A'], self.dataset[i]['R'], 0.0] + self.dataset[i]['box']
      record += [ self.dataset[i]['Sp'] ] + self.dataset[i]['Xp'] + [ self.dataset[i]['Sc']] + self.dataset[i]['Xc']
      record += [ self.dataset[i]['Ap'] ]

      if i < numTrain:
        try: 
          train[imgPath].append(record)
        except: 
          train[imgPath] = [ record ]
      else:
        try: val[imgPath].append(record)
        except: 
          val[imgPath] = [ record ]

    return train, val

  def computeNextMaxQ(self, controller, records):
    print 'Computing discounted reward for all memory samples'
    if controller.net == None:
      return records
    for img in records.keys():
      imSize = Image.open(img).size
      states = []
      imName = img.split('/')[-1].replace('.jpg','') # Extract image name only from the full image path
      for i in range(len(records[img])):
        ol = sol.SingleObjectLocalizer(imSize, records[img][i][3:7], records[img][i][12])
        ol.recoverState(records[img][i])
        ol.performAction(records[img][i][0], [0,0])
        states.append(ol)
      maxQ = np.max( controller.getActionValues( [imName, states] ), 1 ) 
      for i in range(len(maxQ)):
        if records[img][i][0] > 1: # Not a terminal action
          records[img][i][2] = self.gamma*maxQ[i]
        else:
          records[img][i][2] = 0.0
    return records
