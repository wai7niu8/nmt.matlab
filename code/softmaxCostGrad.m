%%%
%
% Perform softmax prediction and backprop.
%
% From the point of view of the model graph structure, this method handles
% all subgraphs from the LSTM hiddent state to the softmax predictions,
% i.e., there can be other intermediate layers for the case of positional
% models, attention functions, and softmax compression.
%
% Thang Luong @ 2015, <lmthang@stanford.edu>
%
%%%
function [costs, softmaxGrad, otherGrads] = softmaxCostGrad(model, params, trainData, topHidVecs)
  curBatchSize = params.curBatchSize;
  T = trainData.T;
  srcMaxLen = trainData.srcMaxLen;
  tgtMaxLen = trainData.tgtMaxLen;
  tgtMask = trainData.tgtMask;
  srcHidVecs = trainData.srcHidVecs;
  % srcHidVecs = reshape([topHidVecs{:, 1:params.numSrcHidVecs}], params.lstmSize, curBatchSize, params.numSrcHidVecs);
  
  % init grads
  [softmaxGrad, otherGrads] = initSoftmaxGrad(model, params);
  if params.attnFunc>0 || params.posModel==3
    softmaxGrad.srcHidVecs = zeroMatrix([params.lstmSize, curBatchSize, params.numSrcHidVecs], params.isGPU, params.dataType);
  end
  otherGrads.ht = cell(1, tgtMaxLen);
  
  % init costs
  costs.total = zeroMatrix([1, 1], params.isGPU, params.dataType);
  if params.posModel>=0
    costs.word = zeroMatrix([1, 1], params.isGPU, params.dataType);
    costs.pos = zeroMatrix([1, 1], params.isGPU, params.dataType);
  end
    
  % attention
  if params.attnFunc > 0
    batchData.srcHidVecs = zeroMatrix([params.lstmSize, params.curBatchSize, params.numAttnPositions], params.isGPU, params.dataType);
    if params.attnFunc==1
      % note that src sentences are reversed.
      batchData.srcHidVecs(:, :, params.numAttnPositions-params.numSrcHidVecs+1:params.numAttnPositions) = srcHidVecs; % params.numAttnPositions = maxSentLen-1 >= params.numSrcHidVec
      startAttnId = 1;
      endAttnId = params.numSrcHidVecs;
      startHidId = params.numAttnPositions-params.numSrcHidVecs+1;
      endHidId = params.numAttnPositions;
    end
  else
    batchData.srcHidVecs = [];
  end
  
  %% predict words from srcMaxLen to T
  for startT=srcMaxLen:params.softmaxStep:T
    endT = startT + params.softmaxStep -1;
    if endT>T
      endT = T;
    end
    numTimeSteps = (endT-startT+1);
    numExamples = numTimeSteps*curBatchSize;
    range = startT:endT;
    tgtPos = (startT-srcMaxLen+1);
    tgtRange = tgtPos:(endT-srcMaxLen+1);
    
    % prepare mask
    if numTimeSteps>1
      curMask.mask = reshape(tgtMask(:, tgtRange), 1, numExamples);
      curMask.unmaskedIds = find(curMask.mask);
      curMask.maskedIds = find(~curMask.mask);
      curMask.count = length(curMask.unmaskedIds);
    else
      curMask = trainData.maskInfo{startT};
    end
    
    % predicted words
    predWords = reshape(trainData.tgtOutput(:, tgtRange), 1, numExamples);
    
    % h_t
    h_t = [topHidVecs{:, range}];
    
    % positional model 3: refer to src info, assume softmaxStep==1
    if params.posModel==3
      [batchData.srcPosVecs, batchData.linearIndices] = buildSrcPosVecs(startT, params, trainData, predWords, curMask);
    end

    % attention model 2: relative positions, we assume softmaxStep=1
    if params.attnFunc==2
      [batchData.srcHidVecs, startAttnId, endAttnId, startHidId, endHidId] = buildSrcHidVecs(srcHidVecs, srcMaxLen, tgtPos, params);
    end
    
    % predict
    if params.numClasses>0 % class-based
      predClasses = mod(predWords, params.numClasses) + 1;
      predInClasses = floor((predWords-1)/params.numClasses + 1e-9) + 1;
      [word_cost, word_softmaxGrad, grad_ht , otherBatchGrads] = batchSoftmax('W_soft_class', h_t, predClasses, model, params, trainData, batchData, 0, curMask, predInClasses);
    else % normal softmax
      if params.posModel>=1 && mod(tgtPos, 2)==1 % positions
        predWords = predWords - params.startPosId + 1;
        [word_cost, word_softmaxGrad, grad_ht, otherBatchGrads] = batchSoftmax('W_softPos', h_t, predWords, model, params, trainData, batchData, 1, curMask);
      else % words
        [word_cost, word_softmaxGrad, grad_ht, otherBatchGrads] = batchSoftmax('W_soft', h_t, predWords, model, params, trainData, batchData, 0, curMask);
      end
    end
    
    % costs
    costs.total = costs.total + word_cost;
    if params.posModel>=0 % separate out pos/word perplexities
      if mod(tgtPos, 2)==0
        costs.word = costs.word + word_cost;
      else
        costs.pos = costs.pos + word_cost;
      end
    end
    
    % update grads
    if trainData.isTest==0
      fields = fieldnames(word_softmaxGrad);
      for ii=1:length(fields)
        field = fields{ii};
        softmaxGrad.(field) = softmaxGrad.(field) + word_softmaxGrad.(field);
      end
      
      % attention models: srcHidVecs      
      if params.attnFunc>0
        softmaxGrad.srcHidVecs(:, :, startAttnId:endAttnId) = softmaxGrad.srcHidVecs(:, :, startAttnId:endAttnId) + otherBatchGrads.srcHidVecs(:, :, startHidId:endHidId);
      end
      
      % positional models
      if params.posModel==3 && mod(tgtPos, 2)==0
        softmaxGrad.srcHidVecs(batchData.linearIndices) = softmaxGrad.srcHidVecs(batchData.linearIndices) + reshape(otherBatchGrads.srcPosVecs(:, curMask.unmaskedIds), 1, []);
      end

      % class-based softmax
      if params.numClasses>0 
        otherGrads.W_soft_inclass(:, :, otherBatchGrads.indices) = otherGrads.W_soft_inclass(:, :, otherBatchGrads.indices) + otherBatchGrads.W_soft_inclass;
        otherGrads.classIndices = unique([otherGrads.classIndices otherBatchGrads.indices]);
      end
            
      % grad_ht      
      for tt=tgtRange
        startId = tt - startT + srcMaxLen; %tt-(startT-srcMaxLen+1)+1;
        otherGrads.ht{1, tt} = grad_ht(:, (startId-1)*curBatchSize+1:startId*curBatchSize);
      end
      
      % assert
      if params.assert && numTimeSteps == 1
        assert(sum(sum(abs(grad_ht(:, curMask.maskedIds))))==0);
      end
    end
  end
end

function [cost, softmaxGrad, grad_ht, otherBatchGrads] = batchSoftmax(matrixName, h_t, origPredLabels, model, params, trainData, batchData, isPredictPos, curMask, varargin) %
%%%
%
% Perform softmax prediction and backprop.
%   matrixName: 'W_soft' for predicting words (mostly used), and
%               'W_softPos' for predicting positions.
% When param.numClasses>0: perform class-based softmax. origPredLabels are class
%   labels. Predicting class labels is like predicting words in the regular
%   softmax. Besides, we need to predict the inclass word indices.
%
%%%
  mask = curMask.mask;
  unmaskedIds = curMask.unmaskedIds;
  maskedIds = curMask.maskedIds;
  
  %% h_t -> softmax_h
  if params.attnFunc>0 % attention mechanism
    [softmax_h, ~, attn_h_concat, alignWeights] = lstm2softHid(h_t, params, model, batchData.srcHidVecs, curMask);
  elseif params.posModel==3 % positional model
    [softmax_h, interSoftInput] = lstm2softHid(h_t, params, model, isPredictPos, batchData.srcPosVecs); %, curMask);
  else
    [softmax_h, interSoftInput] = lstm2softHid(h_t, params, model);
  end

  %% softmax_h -> predictions
  [probs, scores, norms] = softmax(model.(matrixName)*softmax_h, mask);
  % cost
  predLabels = origPredLabels(unmaskedIds);
  
  scoreIndices = sub2ind(size(scores), predLabels, unmaskedIds); % 1 * length(tgtPredictedWords)
  cost = - sum(scores(scoreIndices)) + sum(log(norms).*mask);
  
  % class-based softmax
  if params.numClasses > 0
    predInClass = varargin{1};
    predInClass = predInClass(unmaskedIds);
    
    % in class loss
    % model.W_soft_inclass(:,:,curClasses): classSize * softmaxSize * batchSize
    % softmax_h: softmaxSize * batchSize
    % inClassRaw: classSize * batchSize (sum across softmaxSize, dim 2)
    curClasses = origPredLabels;
    inClassRaw = reshape(sum(bsxfun(@times, model.W_soft_inclass(:,:,curClasses), permute(softmax_h, [3 1 2])), 2), params.classSize, params.curBatchSize);
    [inClassProbs, inClassScores, inClassNorms] = softmax(inClassRaw, mask);
    
    inClassScoreIndices = sub2ind(size(inClassScores), predInClass, unmaskedIds);
    inClassCost = - sum(inClassScores(inClassScoreIndices)) + sum(log(inClassNorms).*mask);
    
    cost = cost + inClassCost;
  end
  
  %% grad
  softmaxGrad = [];
  grad_ht = [];
  otherBatchGrads = [];
  if trainData.isTest==0 % compute grad
    %% loss -> grad_softmax_h
    probs(scoreIndices) = probs(scoreIndices) - 1; % minus one at predicted words

    % softmax_h
    grad_softmax_h = model.(matrixName)'* probs;
    
    % class-based softmax
    if params.numClasses > 0 
      inClassProbs(inClassScoreIndices) = inClassProbs(inClassScoreIndices) - 1;

      % W_soft_inclass(:,:,curClasses): classSize * softmaxSize * batchSize
      % inClassProbs: classSize * batchSize
      % grad_softmax_h: softmaxSize * batchSize (sum across classSize, dim 1)
      grad_softmax_h = grad_softmax_h + squeeze(sum(bsxfun(@times, model.W_soft_inclass(:,:,curClasses), permute(inClassProbs, [1 3 2])), 1));
    end

    if params.assert && ~isempty(maskedIds)
      assert(sum(sum(abs(grad_softmax_h(:, maskedIds))))==0);
    end
    
    %% grad_softmax_h -> h_t
    if params.softmaxDim>0 || params.attnFunc>0 || (params.posModel==3 && isPredictPos==0) % softmax compression or attention
      if params.softmaxDim>0 || params.posModel==3 % f(W_h * interSoftInput)
        % f'(softmax_h).*grad_softmax_h
        tmpResult = params.nonlinear_f_prime(softmax_h).*grad_softmax_h;

        % grad.W_h
        softmaxGrad.W_h = tmpResult*interSoftInput';

        if params.softmaxDim>0
          % grad_ht
          grad_ht = model.W_h'*tmpResult;
        else
          % grad_srcPosH: [srcPosVecs; h_t]
          grad_srcPosH = model.W_h'*tmpResult;
          
          % grad_ht
          grad_ht = grad_srcPosH(params.lstmSize+1:end, :);
          
          % grad srcPosVecs
          otherBatchGrads.srcPosVecs = grad_srcPosH(1:params.lstmSize, :);
        end
      elseif params.attnFunc>0 % f(W_ah*[attn_t; tgt_h_t])
        if params.assert && ~isempty(maskedIds)
          assert(sum(sum(abs(attn_h_concat(:, maskedIds))))==0);
        end
        [softmaxGrad, grad_ht, otherBatchGrads.srcHidVecs] = attnBackprop(model, batchData.srcHidVecs, softmax_h, grad_softmax_h, attn_h_concat, alignWeights, h_t, params, curMask);
      end
    else % normal softmax
      grad_ht = grad_softmax_h;
    end
    
    %% loss -> W_soft. 
    % Note: do not move this part up; otherwise, the case attnFunc>0 will
    % fail because softmaxGrad is only created after calling attnBackprop,
    % which means anything touches softmaxGrad before will be lost.
    softmaxGrad.(matrixName) = probs*softmax_h';
    
    if params.numClasses>0 % class-based softmax
      numWords = length(unmaskedIds);
      % inClassProbs(:, unmaskedIds): classSize * numWords
      % softmax_h(:, unmaskedIds): softmaxSize * numWords
      % W_soft_inclass: classSize * softmaxSize * numWords
      W_soft_inclass_grads = bsxfun(@times, permute(inClassProbs(:, unmaskedIds),[1 3 2]), permute(softmax_h(:, unmaskedIds),[3 1 2]));
      
      % grad.W_soft_inclass: (classSize * softmaxSize) * numWords
      W_soft_inclass_grads = reshape(W_soft_inclass_grads, [params.classSize*params.softmaxSize numWords]);
      
      % accumulate
      [otherBatchGrads.W_soft_inclass, otherBatchGrads.indices] = aggregateMatrix(W_soft_inclass_grads, curClasses(unmaskedIds), params.isGPU, params.dataType);
      otherBatchGrads.W_soft_inclass = reshape(otherBatchGrads.W_soft_inclass, [params.classSize params.softmaxSize length(otherBatchGrads.indices)]);
    end
  end % end isTest
  
  
  % assert
  if params.assert
    if params.isGPU
      assert(gather(sum(sum(abs(scores(:, maskedIds)))))==0);
    else
      assert(sum(sum(abs(scores(:, maskedIds))))==0);
    end
    
    if params.numClasses > 0
      if params.isGPU
        assert(gather(sum(sum(abs(inClassScores(:, maskedIds)))))==0);
      else
        assert(sum(sum(abs(inClassScores(:, maskedIds))))==0);
      end
    end
  end
end

function [softmaxGrad, otherGrads] = initSoftmaxGrad(model, params)
  for ii=1:length(params.softmaxVars)
    field = params.softmaxVars{ii};
    softmaxGrad.(field) = zeroMatrix(size(model.(field)), params.isGPU, params.dataType);
  end
  
  if params.numClasses == 0 % normal
    otherGrads = [];
  else % class-based
    otherGrads.W_soft_inclass = zeroMatrix(size(model.W_soft_inclass), params.isGPU, params.dataType);
    otherGrads.classIndices = [];
  end
end

  
  
%   if params.posModel==2
%     otherGrads.allEmbIndices(wordCount+1:end) = [];
%     otherGrads.allEmbGrads(:, wordCount+1:end) = [];  
%     otherGrads.wordCount = wordCount;
%   end

  % positional
%   if params.posModel==2
%     wordCount = 0;
%     otherGrads.allEmbGrads = zeroMatrix([params.lstmSize, trainData.numInputWords], params.isGPU, params.dataType);
%     otherGrads.allEmbIndices = zeros(trainData.numInputWords, 1);
%   end
    
%         if params.posModel==3 % hidden states
%           [linearIndices] = getTensorLinearIndices(srcHidVecs, curMask.unmaskedIds, batchData.colIndices);
%           softmaxGrad.srcHidVecs(batchData.linearIndices) = softmaxGrad.srcHidVecs(batchData.linearIndices) + reshape(otherBatchGrads.srcPosVecs(:, curMask.unmaskedIds), 1, []);
%         elseif params.posModel==2 % embeddings
%           numWords = length(batchData.srcEmbIndices);
%           otherGrads.allEmbIndices(wordCount+1:wordCount+numWords) = batchData.srcEmbIndices;
%           otherGrads.allEmbGrads(:, wordCount+1:wordCount+numWords) = otherBatchGrads.srcPosVecs(:, curMask.unmaskedIds);        
%           wordCount = wordCount + numWords;
%         end

      %srcPosData = repmat(struct('eosIds', [], 'nullIds', [], 'posIds', [], 'colIndices', [], 'embIndices', []), numTimeSteps, 1); 
      %batchData = struct('srcPosVecs', zeroMatrix([params.lstmSize, curBatchSize, numTimeSteps], params.isGPU, params.dataType), ...
      %  'posIds', [], 'nullIds', [], 'eosIds', [], 'colIndices', []);
      %for t=1:numTimeSteps
      %  [batchData.srcPosVecs(:, :, t), srcPosData(t)] = buildSrcPosVecs(t+startT-1, model, params, trainData, trainData.maskInfo{t+startT-1});
      %end
      %batchData.posIds = [srcPosData(:).posIds];
      %batchData.nullIds = [srcPosData(:).nullIds];
      %batchData.eosIds = [srcPosData(:).eosIds];
      %batchData.colIndices = [srcPosData(:).colIndices];
      
%% positional model 1, 2: predict positions from (srcMaxLen-1) to (T-1)
  %% positional model 3: predict positions from srcMaxLen to T
%   if params.posModel==1 || params.posModel==2
%     origStartT = srcMaxLen-1;
%     origEndT = T-1;
%   elseif params.posModel==3
%     origStartT = srcMaxLen;
%     origEndT = T;
%     
%     otherGrads.allEmbGrads(:, wordCount+1:end) = [];
%     otherGrads.allEmbIndices(wordCount+1:end) = [];
%   end    
%   if params.posModel>0
%     isPredictPos = 1;
%     for startT=origStartT:params.softmaxStep:origEndT
%       endT = startT + params.softmaxStep -1;
%       if endT>origEndT
%         endT = origEndT;
%       end
%       numTimeSteps = (endT-startT+1);
%       numExamples = numTimeSteps*curBatchSize;
%       range = startT:endT;
% 
%       % predicted positions
%       predPositions = reshape(trainData.srcPos(:, (startT-origStartT+1):(endT-origStartT+1)), 1, numExamples) - (params.startPosId-1);
%     
%       % h_t
%       h_t = reshape(topHidVecs(:, :, range), params.lstmSize, numExamples);
% 
%       % prepare mask
%       curMask.mask = reshape(inputMask(:, range), 1, numExamples);
%       curMask.unmaskedIds = find(curMask.mask);
%       curMask.maskedIds = find(~curMask.mask);
% 
%       [pos_cost, pos_softmaxGrad, pos_ht_grad] = batchSoftmax('W_softPos', h_t, predPositions, model, params, trainData, batchData, curMask, isPredictPos);
%       costs.total = costs.total + pos_cost;
%       costs.pos = costs.pos + pos_cost;
%       
%       % grads
%       if trainData.isTest==0
%         fields = fieldnames(pos_softmaxGrad);
%         for ii=1:length(fields)
%           field = fields{ii};
%           softmaxGrad.(field) = softmaxGrad.(field) + pos_softmaxGrad.(field);
%         end
%         
%         % grad_ht
%         otherGrads.ht(:, :, range) = otherGrads.ht(:, :, range) + reshape(pos_ht_grad, [params.lstmSize, curBatchSize, numTimeSteps]);
%       end
%     end
%   end



%       if params.attnFunc==1
%         %otherBatchGrads.srcHidVecs = bsxfun(@times, otherBatchGrads.srcHidVecs, srcHidVecMask);
%         softmaxGrad.srcHidVecs = softmaxGrad.srcHidVecs + otherBatchGrads.srcHidVecs;
%       elseif params.attnFunc==2
%         % mask: 1 * curBatchSize
%         % srcHidVecs: lstmSize * curBatchSize * numAttnPoints
%         % mask out grad before accumulating
%         softmaxGrad.srcHidVecs(batchData.trainLinearIndices) = softmaxGrad.srcHidVecs(batchData.trainLinearIndices) + otherBatchGrads.srcHidVecs(batchData.batchLinearIndices);
%       end

%       batchData.startAttnId = startAttnId;
%       batchData.endAttnId = endAttnId;
%       batchData.startHidId = startHidId;
%       batchData.endHidId = endHidId;

%       % srcMaxLen-(srcLens(i)-1) -> srcMaxLen-1
%       srcPositions = params.numSrcHidVecs + 1 - srcLens(curMask.unmaskedIds) + tgtPos; %srcMaxLen - srcLens + tgtPos - 1;
%       startAttnIds = srcPositions-params.posWin;
%       endAttnIds = srcPositions + params.posWin;
%       startHidIds = ones(1, curMask.count);
%       endHidIds = params.numAttnPositions * ones(1, curMask.count);
%       
%       % start < 1
%       flagIndices = find(startAttnIds<1);
%       startHidIds(flagIndices) = startHidIds(flagIndices) - (startAttnIds(flagIndices)-1);
%       startAttnIds(flagIndices) = 1; % Note: don't swap these two lines
%        
%       % > numSrcHidVecs
%       flagIndices = find(endAttnIds>params.numSrcHidVecs);
%       endHidIds(flagIndices) = endHidIds(flagIndices) - (endAttnIds(flagIndices)-params.numSrcHidVecs);
%       endAttnIds(flagIndices) = params.numSrcHidVecs; % Note: don't swap these two lines
%         
%       % populate srcHidVecs: have to use for loop.
%       batch_srcHidVecs = zeroMatrix([params.lstmSize, params.curBatchSize, params.numAttnPositions], params.isGPU, params.dataType);
%       yIds = zeros(1, params.curBatchSize*params.numAttnPositions);
%       batch_zIds = zeros(1, params.curBatchSize*params.numAttnPositions);
%       train_zIds = zeros(1, params.curBatchSize*params.numAttnPositions);
%       numHidVecs = 0;
%       
%       for ii=1:curMask.count
%         count = endHidIds(ii) - startHidIds(ii) + 1;
%         if count<=0
%           continue;
%         end
%         yIds(numHidVecs+1:numHidVecs+count) = curMask.unmaskedIds(ii)*ones(1, count);
%         batch_zIds(numHidVecs+1:numHidVecs+count) = startHidIds(ii):endHidIds(ii);
%         train_zIds(numHidVecs+1:numHidVecs+count) = startAttnIds(ii):endAttnIds(ii);
%         numHidVecs = numHidVecs + count;
%         % batchData.srcHidVecs(:, ii, startHidIds(ii):endHidIds(ii)) = trainData.srcHidVecs(:, ii, startAttnIds(ii):endAttnIds(ii));
%       end
%       yIds(numHidVecs+1:end) = [];
%       batch_zIds(numHidVecs+1:end) = [];
%       train_zIds(numHidVecs+1:end) = [];
%       batchData.batchLinearIndices = getTensorLinearIndices(batch_srcHidVecs, yIds, batch_zIds);
%       batchData.trainLinearIndices = getTensorLinearIndices(srcHidVecs, yIds, train_zIds);
%       batch_srcHidVecs(batchData.batchLinearIndices) = srcHidVecs(batchData.trainLinearIndices);