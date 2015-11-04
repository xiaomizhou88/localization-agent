-- Imports
require 'nn'
require 'rnn'
require 'cutorch'
require 'cunnx'

require 'sys'
require 'paths'
require 'hdf5'

cmd = torch.CmdLine()
cmd:option('-workingDir','/home/jccaicedo/data/tracking/simulations/debug/','Directory where files are written and loaded')
cmd:option('-iter',200,'Number of iterations')
params = cmd:parse(arg or {})

gpu = true
workingDir = params.workingDir

if paths.filep(workingDir .. 'net.snapshot.bin') then
  print('Loading pretrained network')
  net = torch.load(workingDir .. 'net.snapshot.bin')
else
  -- ConvNet 1
  convnet1 = nn.Sequential()
  convnet1:add( nn.SpatialConvolution(3,64,5,5,2,2,1,1) )       --  64 -> 32
  convnet1:add( nn.ReLU(true) )
  convnet1:add( nn.SpatialConvolution(64,128,3,3,1,1,2,2) )      --  32 -> 32
  convnet1:add( nn.SpatialMaxPooling(3,3,2,2) )                   -- 32 -> 16
  convnet1:add( nn.ReLU(true) )
  convnet1:add( nn.SpatialConvolution(128,128,3,3,1,1,1,1) )      --  16 ->  15
  convnet1:add( nn.ReLU(true) )
  convnet1:add( nn.SpatialConvolution(128,128,3,3,1,1,1,1) )      --  15 -> 14
  convnet1:add( nn.SpatialMaxPooling(3,3,2,2) )                   -- 14 -> 7
  convnet1:add( nn.ReLU(true) )
  convnet1:add( nn.View(128*7*7) )
  convnet1:add( nn.Dropout(0.5) )
  convnet1:add( nn.Linear(128*7*7, 2048) )

  -- ConvNet 2
  convnet2 = nn.Sequential()
  convnet2:add( nn.SpatialConvolution(3,64,5,5,2,2,1,1) )       --  64 -> 32
  convnet2:add( nn.ReLU(true) )
  convnet2:add( nn.SpatialConvolution(64,128,3,3,1,1,2,2) )      --  32 -> 32
  convnet2:add( nn.SpatialMaxPooling(3,3,2,2) )                   -- 32 -> 16
  convnet2:add( nn.ReLU(true) )
  convnet2:add( nn.SpatialConvolution(128,128,3,3,1,1,1,1) )      --  16 ->  15
  convnet2:add( nn.ReLU(true) )
  convnet2:add( nn.SpatialConvolution(128,128,3,3,1,1,1,1) )      --  15 -> 14
  convnet2:add( nn.SpatialMaxPooling(3,3,2,2) )                   -- 14 -> 7
  convnet2:add( nn.ReLU(true) )
  convnet2:add( nn.View(128*7*7) )
  convnet2:add( nn.Dropout(0.5) )
  convnet2:add( nn.Linear(128*7*7, 2048) )

  -- Parallel net
  net = nn.Sequential()
  convnets = nn.Parallel(2,2)
  convnets:add(convnet1)
  convnets:add(convnet2)
  net:add( nn.Sequencer(convnets) )

  -- LSTM
  inputSize = 4096
  hiddenSize = 512
  nIndex = 9 -- possible actions
  lstm = nn.Sequencer(nn.FastLSTM(inputSize, hiddenSize))

  -- Prediction Layers
  net:add( lstm )
  net:add( nn.Sequencer( nn.Linear(hiddenSize,nIndex) ) )
  net:add( nn.Sequencer( nn.LogSoftMax() ) )
end

print(net)

criterion = nn.SequencerCriterion(nn.ClassNLLCriterion())

-- GPU based
if gpu then
  net = net:cuda()
  criterion = criterion:cuda()
end

-- Training
schedule = {0.01,0.005,0.001}
updateInterval = 10
iterations = params.iter
batchSize = 24
-- Data size and dimensions
simulationFile = workingDir .. 'simulation.hdf5'
numVideos = (16*3)-1 -- Generated by the SimulationServer
seqPerVideo = 1  -- From each video, how many sequences are extracted
movesPerSeq = 50 -- Number of box search moves in each sequence
-- Loop vars
i = 1
avgErr = 0
t = torch.Timer()

function getBatches()
   -- Search simulation data
   while not paths.filep(simulationFile) or not paths.filep(simulationFile .. '.ready') do
     sys.sleep(0.1)
   end
   -- Read all sequences in the simulation file
   local data = hdf5.open(simulationFile, 'r')
   local frames = {}
   local moves = {}
   for j=0,numVideos do
     frames[j] = data:read('frames'..j):all()
     moves[j] = data:read('targets'..j):all()
   end
   fSize = frames[0]:size()
   mSize = moves[0]:size()
   data:close()
   sys.execute('rm ' .. simulationFile)
   sys.execute('rm ' .. simulationFile .. '.ready')
   -- Split videos in sequences of frames
   local inputs = {}
   local targets = {}
   for j=0,numVideos do
     for m=1,seqPerVideo do
       -- Prepare tables for one sequence
       local sequence = {}
       local targetOut = {}
       for n=1,movesPerSeq do
         sequence[n] = frames[j][{ {(m-1)*movesPerSeq + n}, {}, {}, {}, {}  }]
         targetOut[n] = moves[j][{ {(m-1)*movesPerSeq + n}, {} }]
       end
       table.insert(inputs, sequence)
       table.insert(targets, targetOut)
     end
   end
   -- Organize batches
   local batches = {}
   local allBatches = torch.floor(#inputs/batchSize)
   local permIdx = torch.randperm(#inputs)
   for i=1,allBatches do
     batches[i] = {}
     batches[i].inputs = {} 
     batches[i].targets = {}
     for j=1,movesPerSeq do
       I = torch.Tensor(batchSize,fSize[2],fSize[3],fSize[4],fSize[5])
       T = torch.Tensor(batchSize)
       for k=1,batchSize do
         idx = permIdx[(i-1)*batchSize + k]
         I[{{k},{},{},{},{}}] = inputs[idx][j]
         T[{{k}}] = targets[idx][j] + 1
       end
       batches[i].inputs[j] = I:cuda()
       batches[i].targets[j] = T:cuda()
     end
   end
   return batches
end

timer = torch.Timer()
t = torch.Timer()
net:training()
print('Training begins')
while i < iterations do
   batches = getBatches()
   for k=1,#batches do
     -- Feed data to the network
     local output = net:forward(batches[k].inputs)
     local err = criterion:forward(output, batches[k].targets)
     net:zeroGradParameters()
     -- Update network parameters
     local gradOutput = criterion:backward(output, batches[k].targets)
     local netGrad = net:backward(batches[k].inputs, gradOutput)
     local lr = schedule[ torch.ceil((i/iterations)*#schedule) ] or schedule[#schedule]
     net:updateGradParameters(0.9)
     net:updateParameters(lr)
     -- Update counters and print messages
     i = i + 1
     avgErr = avgErr + err
     if i % updateInterval == 0 then
        print(i,avgErr/updateInterval,t:time().real)
        avgErr = 0
        t = torch.Timer()
     end
   end
end
print('Total training time: ' .. timer:time().real)
torch.save(workingDir .. 'net.snapshot.bin', net:float())
sys.execute('rm ' .. simulationFile .. '.running')
